# frozen_string_literal: true

class Regexp::BacktrackingAnalysis::Analyzer
  def initialize(root, max_witness_length, trend_sizes)
    @root = root
    @max_witness_length = max_witness_length
    @trend_sizes = trend_sizes
    @findings = []
    @reported = {}
  end

  def analyze
    unsupported = Regexp::BacktrackingAnalysis::Support.unsupported(@root)
    return unknown(unsupported) if unsupported

    scan_expressions(@root.expressions)
    status = @findings.empty? ? :safe : :vulnerable
    Regexp::BacktrackingAnalysis::Result.new(status, @findings, nil)
  rescue Regexp::BacktrackingAnalysis::UnsupportedFeature => error
    unknown(error)
  end

  private

  def unknown(error)
    expression = error.respond_to?(:expression) ? error.expression : nil
    location = expression ? Regexp::BacktrackingAnalysis.location(expression, 'unsupported AST node') : nil
    Regexp::BacktrackingAnalysis::Result.new(
      :unknown,
      [],
      Regexp::BacktrackingAnalysis::Finding.new(
        :unknown, error.message, [location].compact, nil, nil
      )
    )
  end

  def scan_expressions(expressions)
    linearize(expressions, []).each { |segment| scan_linear_segment(segment) }
  end

  def scan_expression(exp, current)
    if exp.is_a?(Regexp::Expression::Alternation)
      exp.expressions.each { |alt| scan_expressions(alt.expressions) }
      return barrier(current)
    end

    if terminal_atom?(exp)
      check_quantified_family(exp) if exp.quantified?
      return current << exp
    end

    if exp.is_a?(Regexp::Expression::Group::Atomic) || exp.possessive?
      scan_expressions(exp.expressions)
      return barrier(current)
    end

    if unbounded?(exp)
      check_quantified_family(exp)
      scan_expressions(exp.expressions)
      return barrier(current)
    end

    if exp.quantified?
      check_quantified_family(exp)
      scan_expressions(exp.expressions)
      return exp.quantifier.max == 1 ? current << exp : barrier(current)
    end

    if contains_alternation?(exp)
      scan_expressions(exp.expressions)
      barrier(current)
    else
      scan_expressions(exp.expressions)
      current
    end
  end

  def linearize(expressions, current)
    segments = []
    expressions.each do |exp|
      next if skip?(exp)

      if mergeable_container?(exp)
        nested = linearize(exp.expressions, [])
        next if nested.empty?

        current.concat(nested.first)
        if nested.length > 1
          segments << current unless current.empty?
          segments.concat(nested[1..-2])
          current = nested.last
        end
        next
      end

      result = scan_expression(exp, current)
      if result.equal?(:barrier)
        current = []
      else
        current = result
      end
    end
    segments << current unless current.empty?
    segments
  end

  def mergeable_container?(exp)
    !exp.terminal? &&
      !exp.is_a?(Regexp::Expression::CharacterSet) &&
      !exp.quantified? &&
      !exp.is_a?(Regexp::Expression::Group::Atomic) &&
      !exp.is_a?(Regexp::Expression::Alternation)
  end

  def barrier(current)
    :barrier
  end

  def scan_linear_segment(segment)
    flexible = segment.each_index.select { |index| unbounded_flexible?(segment[index]) }
    flexible.each_cons(2) do |left_index, right_index|
      left = segment[left_index]
      right = segment[right_index]
      check_adjacent_family(left, right, segment[0..right_index])
    end
  end

  def check_quantified_family(exp)
    return if exp.possessive? || exp.is_a?(Regexp::Expression::Group::Atomic)

    witness = ambiguous_witness(exp)
    return unless witness

    severity = quantified_severity(exp, witness.repeatable)
    return unless severity

    report(
      severity,
      'unbounded repetition has multiple decompositions of the same input',
      ambiguity_locations(exp, witness),
      witness
    )
  end

  def check_adjacent_family(left, right, prefix_expressions = nil)
    witness = overlap_witness(left, right)
    return unless witness

    if prefix_expressions && !prefix_ambiguous?(prefix_expressions, witness.repeatable)
      return
    end

    report(
      :polynomial,
      'adjacent unbounded matchers overlap and can both consume the same input',
      [
        Regexp::BacktrackingAnalysis.location(left, 'first overlapping repetition'),
        Regexp::BacktrackingAnalysis.location(right, 'second overlapping repetition')
      ],
      witness
    )
  end

  def ambiguous_witness(exp)
    @pending_prefix = fixed_prefix_before(exp.parent, exp)
    candidate_words(exp).each do |word|
      @trend_sizes.each do |size|
        next unless size >= 2

        pumped = word * size
        counter = path_counter(pumped)
        next unless counter.ambiguous?(exp, 0, pumped.length)

        suffix = failure_suffix(exp.parent, exp, word)
        if suffix
          context = @suffix_context.to_s
          checked = context.empty? ? pumped : pumped + context
          if context.empty? || path_counter(checked).ambiguous_followed_by?(exp, context)
            @ambiguous_length = size
            return build_witness(word, suffix)
          end
        end
        @suffix_context = nil
      end
    end
    nil
  end

  def overlap_witness(left, right)
    @pending_prefix = fixed_prefix_before(left.parent, left)
    @suffix_context = nil
    words = candidate_words(left) & candidate_words(right)
    words.each do |word|
      next unless single_matches?(left, word) && single_matches?(right, word)

      suffix = failure_suffix_for_pair(left, right, word)
      next unless suffix

      return build_witness(word, suffix)
    end
    nil
  end

  def build_witness(word, suffix)
    Regexp::BacktrackingAnalysis::Witness.new(@pending_prefix.to_s, word, suffix)
  end

  def failure_suffix_for_pair(left, right, word)
    @failure_blockers = [left, right]
    failure_suffix(right.parent, right, word)
  ensure
    @failure_blockers = nil
  end

  def candidate_words(exp)
    @candidate_words ||= {}
    @candidate_words[exp.object_id] ||= begin
      words = Regexp::BacktrackingAnalysis::Support.terminals(exp, @max_witness_length)
      words.flat_map { |word| repeatable_roots(word) }.uniq
    end
  end

  def repeatable_roots(word)
    (1..word.length).map do |length|
      next unless word.length % length == 0

      part = word[0, length]
      part if word == part * (word.length / length)
    end.compact
  end

  def ambiguity_locations(exp, witness)
    locations = [Regexp::BacktrackingAnalysis.location(exp, 'ambiguous unbounded repetition')]
    nested = nested_ambiguity_node(exp, witness, @ambiguous_length || 2)
    locations << Regexp::BacktrackingAnalysis.location(nested, 'ambiguous nested matcher') if nested
    locations
  end

  def quantified_severity(exp, word)
    return :exponential if exp.quantifier.max < 0
    return :polynomial if pumpable_descendant?(exp, word)

    nil
  end

  def pumpable_descendant?(exp, word)
    descendants(exp).any? do |child|
      next false unless child.quantified? && child.quantifier.max < 0
      next false if child.possessive? || child.is_a?(Regexp::Expression::Group::Atomic)

      single_matches?(child, word * 2) && single_matches?(child, word * 3)
    end
  end

  def nested_ambiguity_node(exp, witness, ambiguous_length)
    candidates = []
    descendants(exp).each do |child|
      next if child.equal?(exp)
      next unless child.quantified? && !child.possessive?
      next if child.is_a?(Regexp::Expression::Group::Atomic)

      candidates << child if single_matches?(child, witness.repeatable)
    end
    alternation = descendants(exp).detect do |child|
      child.is_a?(Regexp::Expression::Alternation) &&
        alternation_ambiguous?(child, witness, ambiguous_length)
    end
    candidates << alternation if alternation
    candidates.min_by { |node| [node.starts_at, node.full_length] }
  end

  def alternation_ambiguous?(exp, witness, length = 1)
    matches = exp.expressions.count do |alt|
      (1..length).any? do |size|
        pumped = witness.repeatable * size
        path_counter(pumped).matches?(alt, 0, pumped.length)
      end
    end
    matches > 1
  end

  def failure_suffix(container, stop_at, witness)
    chain = ancestor_chain(container, stop_at)
    chain.each_cons(2) do |parent, node|
      next unless node.equal?(stop_at) || crossable_parent?(node)
      next unless parent.respond_to?(:expressions)

      index = parent.expressions.index { |exp| exp.equal?(node) }
      next unless index

      following = parent.expressions[(index + 1)..-1].to_a.reject { |exp| skip?(exp) }
      required = first_required_expression(following)
      next unless required

      trigger = trigger_character(required, witness, stop_at)
      next unless trigger

      tail = required_tail(following, required)
      failure = terminal_failure_character(required, trigger, witness, stop_at)
      next unless failure

      @suffix_context = trigger
      return trigger + tail + failure
    end
    nil
  end

  def fixed_prefix_before(container, stop_at)
    prefix = String.new
    ancestor_chain(container, stop_at).each_cons(2) do |parent, node|
      next unless parent.respond_to?(:expressions)

      index = parent.expressions.index { |exp| exp.equal?(node) }
      next unless index

      parent.expressions[0...index].reverse_each do |exp|
        next if skip?(exp)
        break unless required_once?(exp)

        if terminal_atom?(exp)
          part = terminal_prefix(exp)
          prefix = part + prefix if part
        elsif !exp.quantified? && transparent_container?(exp)
          nested = fixed_prefix_in_container(exp)
          prefix = nested + prefix unless nested.empty?
        else
          break
        end
      end
    end
    prefix
  end

  def fixed_prefix_in_container(container)
    result = String.new
    container.expressions.each do |exp|
      next if skip?(exp)
      break unless required_once?(exp)

      if exp.terminal?
        part = terminal_prefix(exp)
        result << part if part
      elsif !exp.quantified? && transparent_container?(exp)
        result << fixed_prefix_in_container(exp)
      else
        break
      end
    end
    result
  end

  def first_required_expression(expressions)
    expressions.each do |exp|
      next if skip?(exp)
      return nil unless required_once?(exp)

      if terminal_atom?(exp)
        return exp
      elsif !exp.quantified? && transparent_container?(exp)
        nested = first_required_expression(exp.expressions)
        return nested if nested
      else
        return nil
      end
    end
    nil
  end

  def required_tail(expressions, stop_expression)
    seen = false
    result = String.new
    expressions.each do |exp|
      next if skip?(exp)
      break unless required_once?(exp)
      break unless terminal_atom?(exp) || (!exp.quantified? && transparent_container?(exp))

      seen = true if exp.equal?(stop_expression)
      result << required_text(exp) if seen && !exp.equal?(stop_expression)
    end
    result
  end

  def required_text(exp)
    return exp.to_s(:base) if exp.is_a?(Regexp::Expression::Literal)
    return exp.char.to_s if exp.is_a?(Regexp::Expression::EscapeSequence::Base) && exp.respond_to?(:char)

    ''
  end

  def required_once?(exp)
    !exp.quantified? || (exp.quantifier.min == 1 && exp.quantifier.max == 1)
  end

  def terminal_prefix(exp)
    if exp.is_a?(Regexp::Expression::Literal)
      exp.to_s(:base)[0, 1]
    elsif exp.is_a?(Regexp::Expression::EscapeSequence::Base) && exp.respond_to?(:char)
      exp.char
    else
      nil
    end
  end

  def trigger_character(required, witness, stop_at = nil)
    candidates = ['a', 'b', 'c', '0', '1', 'z', 'Z', '#', '.', ' ', "\n", "\t", "\uE000"]
    candidates.detect do |char|
      next false if char == witness

      expression_matches?(required, char)
    end
  end

  def terminal_failure_character(required, trigger, witness, stop_at)
    candidates = ['z', 'Z', '0', '#', '.', ' ', "\n", "\t", "\uE000"]
    candidates.detect do |char|
      char != trigger &&
        char != witness &&
        !(blocked_by_quantifier?(stop_at, char)) &&
        !expression_matches?(required, char)
    end
  end

  def blocked_by_quantifier?(exp, char)
    nodes = @failure_blockers || [exp]
    nodes.any? { |node| node && path_counter(char).counts(node, 0).key?(1) }
  end

  def expression_matches?(exp, char)
    Regexp::BacktrackingAnalysis::Characters.matches?(
      exp,
      char,
      (@root.options || {}).merge(exp.options || {})
    )
  rescue Regexp::BacktrackingAnalysis::UnsupportedFeature
    false
  end

  def report(severity, reason, locations, witness)
    key = [severity, locations.map { |location| location.expression.object_id }]
    return if @reported[key]

    @reported[key] = true
    trend = verify_trend(severity, witness)
    return unless trend

    @findings << Regexp::BacktrackingAnalysis::Finding.new(severity, reason, locations, witness, trend)
  end

  def verify_trend(severity, witness)
    step_counts = @trend_sizes.map do |size|
      input = witness.prefix.to_s + (witness.repeatable * size) + witness.suffix
      Regexp::BacktrackingAnalysis::Interpreter.steps(@root, input, @root.options || {})
    end
    growth = classify_growth(step_counts)
    return unless growth == severity

    Regexp::BacktrackingAnalysis::Trend.new(@trend_sizes, step_counts, growth)
  end

  def classify_growth(step_counts)
    pairs = step_counts.each_cons(2)
    ratios = pairs.map { |left, right| left.zero? ? 1.0 : right.to_f / left }
    return :exponential if ratios.all? { |ratio| ratio > 1.85 }
    return :polynomial if ratios.all? { |ratio| ratio > 1.15 } && ratios.inject(:+) > 3.4

    :linear
  end

  def single_matches?(exp, word)
    path_counter(word).matches?(exp, 0, word.length)
  end

  def path_counter(string)
    Regexp::BacktrackingAnalysis::PathCounter.new(string, @root.options || {})
  end

  def prefix_ambiguous?(expressions, word)
    @trend_sizes.any? do |size|
      pumped = word * size
      counter = path_counter(pumped)
      counter.ambiguous_prefix?(expressions, 0, pumped.length)
    end
  end

  def unbounded?(exp)
    exp.quantified? && exp.quantifier.max < 0 && !exp.possessive?
  end

  def unbounded_flexible?(exp)
    unbounded?(exp) && !exp.is_a?(Regexp::Expression::Group::Atomic)
  end

  def terminal_atom?(exp)
    exp.terminal? || exp.is_a?(Regexp::Expression::CharacterSet)
  end

  def transparent_container?(exp)
    !exp.is_a?(Regexp::Expression::Group::Atomic) &&
      !exp.is_a?(Regexp::Expression::Alternation)
  end

  def crossable_parent?(node)
    !node.quantified? &&
      !node.is_a?(Regexp::Expression::Root) &&
      !node.is_a?(Regexp::Expression::Group::Atomic)
  end

  def ancestor_chain(container, node)
    chain = [container, node]
    while chain.first.respond_to?(:parent) && chain.first.parent
      parent = chain.first.parent
      break if !parent.is_a?(Regexp::Expression::Subexpression) &&
               !parent.is_a?(Regexp::Expression::Root)

      chain.unshift(parent)
    end
    chain
  end

  def contains_alternation?(exp)
    exp.each_expression.any? { |child| child.is_a?(Regexp::Expression::Alternation) }
  end

  def descendants(exp)
    return [] if exp.terminal?

    result = [exp]
    exp.each_expression { |child| result << child }
    result
  end

  def skip?(exp)
    exp.decorative? ||
      (exp.is_a?(Regexp::Expression::Group::Options) && exp.token == :options_switch)
  end
end
