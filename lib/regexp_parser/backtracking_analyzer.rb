# frozen_string_literal: true

require_relative 'expression'

class Regexp::BacktrackingAnalyzer
  DEFAULT_VERIFY_TIMEOUT = 0.05
  DEFAULT_VERIFY_LENGTHS = [8, 12, 16].freeze

  RISK_FOUND     = :risk_found
  NO_RISK_FOUND  = :no_risk_found
  UNANALYZABLE   = :unanalyzable
  STATUSES       = [RISK_FOUND, NO_RISK_FOUND, UNANALYZABLE].freeze

  Result = Struct.new(:status, :risks, :unsupported) do
    def initialize(status:, risks: [], unsupported: [])
      super(status, risks, unsupported)
    end

    def risky?
      status == RISK_FOUND
    end
  end

  Risk = Struct.new(:range, :ambiguous_ranges, :suffix_range,
                    :witness, :reason)

  Witness = Struct.new(:prefix, :repeatable, :suffix, :growth) do
    def example(length = 16)
      room = length - prefix.length - suffix.length
      count = repeatable.empty? ? 0 : [room, 0].max / repeatable.length
      prefix + (repeatable * count) + suffix
    end
  end

  Unsupported = Struct.new(:range, :expression, :reason)
  Pump = Struct.new(:fragment, :counts, :ambiguous, :sources)

  def self.analyze(pattern)
    new.analyze(pattern)
  end

  def analyze(pattern)
    root = if pattern.is_a?(Regexp::Expression::Base)
      pattern
    else
      require_relative '../regexp_parser'
      Regexp::Parser.parse(pattern)
    end
    unsupported = collect_unsupported(root)
    risks = unsupported.empty? ? find_risks(root) : []

    status = if unsupported.any?
      UNANALYZABLE
    elsif risks.any?
      RISK_FOUND
    else
      NO_RISK_FOUND
    end

    Result.new(status: status, risks: risks, unsupported: unsupported)
  end

  # This is an auxiliary check for a constructed witness. Risk itself is
  # established structurally. The short timeout keeps this check cheap and
  # prevents it from becoming the detection mechanism. Native regexp matching
  # may not reach a Ruby timeout check point immediately, so callers must still
  # use small witness lengths and treat this only as a sanity check.
  def verify_witness!(pattern, witness, lengths: DEFAULT_VERIFY_LENGTHS,
                      timeout: DEFAULT_VERIFY_TIMEOUT)
    source = pattern.is_a?(Regexp::Expression::Base) ? pattern.to_s : pattern
    regexp = source.is_a?(::Regexp) ? source : ::Regexp.new(source.to_s)

    lengths.each do |length|
      input = witness.example(length)
      matched = Timeout.timeout(timeout) { regexp.match?(input) }
      raise "witness does not exercise #{source.inspect}" unless matched
    end

    true
  end

  private

  def collect_unsupported(root)
    unsupported = []
    root.each_expression do |exp|
      next unless unsupported?(exp)

      unsupported << Unsupported.new(
        range_for(exp), exp,
        "#{human_class(exp)} cannot be included in this conservative proof"
      )
    end
    unsupported + reluctant_inner_quantifiers(root)
  end

  def reluctant_inner_quantifiers(root)
    list = []
    root.each_expression do |exp|
      next unless exp.quantified? && exp.quantifier.reluctant?

      list << Unsupported.new(
        range_for(exp), exp,
        'reluctant inner quantifiers are not included in this greedy backtracking proof'
      )
    end
    list
  end

  def unsupported?(exp)
    exp.referential? ||
      exp.is_a?(Regexp::Expression::Group::Absence) ||
      exp.is_a?(Regexp::Expression::Keep::Mark) ||
      exp.is_a?(Regexp::Expression::Assertion::Base)
  end

  def find_risks(root)
    risks = []
    each_quantified(root) do |exp|
      next unless dangerous?(exp)
      next if sealed_expression?(exp)

      pump = ambiguous_pump(exp)
      next unless pump

      suffix = following_terms(exp, root)
      delimiter = suffix_delimiter(suffix, pump.fragment)
      next unless delimiter

      risks << build_risk(exp, pump, suffix, delimiter, root)
    end
    risks
  end

  def each_quantified(exp, &block)
    return enum_for(__method__, exp) unless block_given?

    exp.each_expression { |child| block.call(child) if child.quantified? }
  end

  def dangerous?(exp)
    exp.quantifier.max == -1 &&
      exp.quantifier.greedy? &&
      minimum_length(exp.unquantified_clone).positive?
  end

  def minimum_length(exp)
    if exp.terminal? || exp.is_a?(Regexp::Expression::CharacterSet)
      exp.match_length.min
    elsif exp.is_a?(Regexp::Expression::Alternation)
      exp.expressions.map { |branch| minimum_length(branch) }.min || 0
    else
      exp.expressions.map { |child| minimum_length(child) }.inject(0, :+)
    end
  rescue StandardError
    0
  end

  # An atomic group or possessive quantifier removes the save point needed for
  # repartitioning an already completed repetition.
  def sealed_expression?(exp)
    exp.is_a?(Regexp::Expression::Group::Atomic) ||
      (exp.quantifier && exp.quantifier.possessive?)
  end

  def ambiguous_pump(exp)
    body = exp.unquantified_clone
    fragments = pump_fragments(body)

    fragments.each do |fragment|
      pump = pump_summary(body, fragment)
      next unless pump
      positive_counts = pump.counts.select(&:positive?)
      next unless positive_counts.length >= 2

      pump.sources << range_for(exp) unless pump.sources.include?(range_for(exp))
      return pump
    end
    nil
  end

  def pump_fragments(exp)
    fragments = []
    collect_pump_fragments(exp, fragments)
    fragments.uniq { |fragment| [fragment, fragment.length] }.first(30)
  end

  def collect_pump_fragments(exp, fragments)
    return if sealed_expression?(exp)

    if exp.is_a?(Regexp::Expression::CharacterSet)
      fragment = terminal_fragment(exp)
      fragments << fragment if fragment && !fragments.include?(fragment)
      return
    end

    if fragment_terminal?(exp)
      fragment = terminal_fragment(exp)
      fragments << fragment if fragment && !fragments.include?(fragment)
      return
    end

    return unless exp.respond_to?(:expressions)

    children = exp.expressions
    children = children.select(&:expressions).flatten if exp.is_a?(Regexp::Expression::Alternation)
    children.each { |child| collect_pump_fragments(child, fragments) }
  end

  def fragment_terminal?(exp)
    exp.terminal? && minimum_length(exp).positive?
  end

  def terminal_fragment(exp)
    return exp.text if exp.is_a?(Regexp::Expression::Literal) && !exp.text.empty?

    candidates = %w[a b c x y z 0 1 2 9 _ . !]
    candidates.find { |char| terminal_matches?(exp, char) }
  end

  def terminal_matches?(exp, fragment)
    return exp.text == fragment if literal_leaf?(exp) && !exp.quantified?

    anchored(exp.to_s(:base)).match?(fragment)
  rescue RegexpError
    false
  end

  def pump_summary(exp, fragment)
    if sealed_expression?(exp)
      counts = [0, 1].select { |count| expression_matches?(exp, fragment * count) }
      return Pump.new(fragment, counts, false, [range_for(exp)])
    end

    if exp.terminal? || exp.is_a?(Regexp::Expression::CharacterSet)
      counts = (0..3).select { |count| expression_matches?(exp, fragment * count) }
      return Pump.new(fragment, counts, false, [range_for(exp)]) if counts.any?
      return nil
    end

    if exp.is_a?(Regexp::Expression::Alternation)
      branch_pumps = exp.expressions.map do |branch|
        branch.expressions.empty? ? Pump.new(fragment, [0], false, []) : sequence_summary(branch.expressions, fragment)
      end.compact
      return nil if branch_pumps.length != exp.expressions.length

      counts = branch_pumps.flat_map(&:counts).uniq.sort
      overlap = branch_pumps.any? do |pump|
        branch_pumps.any? { |other| pump != other && (pump.counts & other.counts).any? { |count| count.positive? } }
      end
      ambiguous = branch_pumps.any?(&:ambiguous) || overlap
      Pump.new(fragment, counts, ambiguous, branch_pumps.flat_map(&:sources).uniq)
    else
      sequence_summary(exp.expressions, fragment)
    end
  end

  def sequence_summary(expressions, fragment)
    pumps = expressions.map { |child| child_summary(child, fragment) }
    return nil if pumps.any?(&:nil?)

    counts = pumps.map(&:counts)
    sums = counts.first || [0]
    counts[1..-1].to_a.each do |count_set|
      sums = sums.product(count_set).map { |left, right| left + right }
    end

    Pump.new(
      fragment, sums.uniq.sort, pumps.any?(&:ambiguous),
      pumps.flat_map(&:sources).uniq
    )
  end

  def child_summary(child, fragment)
    sealed = sealed_expression?(child)
    base = pump_summary(child.unquantified_clone, fragment)
    if base.nil?
      if child.quantified? && child.quantifier.min.zero?
        return Pump.new(fragment, [0], false, [])
      end
      return nil
    end
    return base unless child.quantified?
    unless sealed
      ambiguous = child.quantifier.possessive? ? false : child.quantifier.max != child.quantifier.min
      return Pump.new(fragment, repeated_counts(base.counts, child), ambiguous, [range_for(child)])
    end

    Pump.new(fragment, repeated_counts(base.counts, child), false, [range_for(child)])
  end

  def repeated_counts(counts, exp)
    min = exp.quantifier.min
    max = exp.quantifier.max == -1 ? 3 : [exp.quantifier.max, 3].min
    result = []
    (min..max).each do |repetition|
      counts.each { |count| result << count * repetition }
    end
    result.uniq.sort
  end

  def expression_matches?(exp, string)
    source = if literal_leaf?(exp) && !exp.quantified?
      Regexp.escape(exp.text)
    elsif literal_leaf?(exp)
      exp.to_s
    else
      exp.to_s(:base)
    end
    anchored(source).match?(string)
  rescue RegexpError
    false
  end

  def following_terms(exp, root)
    terms = []
    current = exp
    first = true

    while true
      parent = current.parent || (first ? root : nil)
      break unless parent

      siblings = parent.respond_to?(:expressions) ? parent.expressions : []
      index = siblings.index(current)
      if index
        terms.concat(siblings[(index + 1)..-1].to_a)
      end
      break if parent.is_a?(Regexp::Expression::Alternative)

      current = parent
      first = false
    end

    terms
  end

  def suffix_delimiter(terms, fragment)
    return nil if terms.empty?
    return nil unless terms.any? { |term| required_consuming?(term) }

    ['!', 'x', "\n", "\0", ' '].find do |char|
      !suffix_matches?(terms, fragment + char) &&
        suffix_matches?(terms, char)
    end
  end

  def suffix_matches?(terms, char)
    source = terms.map do |term|
      if literal_leaf?(term) && !term.quantified?
        Regexp.escape(term.text)
      else
        term.to_s
      end
    end.join
    anchored(source).match?(char)
  rescue RegexpError
    true
  end

  def required_consuming?(exp)
    return false if exp.is_a?(Regexp::Expression::Anchor::Base)
    return false if exp.is_a?(Regexp::Expression::Assertion::Base)
    return false if exp.quantified? && exp.quantifier.min.zero?

    minimum_length(exp).positive?
  end

  def build_risk(exp, pump, suffix, delimiter, root)
    witness = Witness.new(
      prefix_before(exp, root), pump.fragment, delimiter.to_s,
      "repeat #{pump.fragment.inspect}; the following suffix rejects that character"
    )
    reason = [
      'overlapping repetitions admit multiple partitions of the same pumped fragment',
      'the following required suffix rejects an additional pumped character',
      'no enclosing atomic group or possessive quantifier closes the ambiguity'
    ].join('; ')

    Risk.new(range_for(exp), pump.sources, suffix_range(suffix), witness, reason)
  end

  def prefix_before(exp, root)
    parts = []
    current = exp
    first = true

    while true
      parent = current.parent || (first ? root : nil)
      break unless parent

      siblings = parent.respond_to?(:expressions) ? parent.expressions : []
      index = siblings.index(current)
      if index
        parts.unshift(*siblings[0...index].map { |term| literal_prefix(term) })
      end
      current = parent
      first = false
    end

    parts.join
  end

  def literal_prefix(exp)
    return minimal_repetitions(exp) { minimal_prefix(exp) } if exp.quantified?
    return minimal_prefix(exp)
  end

  def minimal_repetitions(exp)
    exp.quantifier.min.times.map { yield }.join
  end

  def minimal_prefix(exp)
    return '' if exp.is_a?(Regexp::Expression::Anchor::Base)
    return '' if exp.is_a?(Regexp::Expression::Assertion::Base)
    return representative_character(exp) if exp.is_a?(Regexp::Expression::CharacterSet)
    return representative_character(exp) if exp.is_a?(Regexp::Expression::CharacterType::Base)
    return exp.text if exp.is_a?(Regexp::Expression::Literal)
    return '' if exp.terminal?

    if exp.is_a?(Regexp::Expression::Alternation)
      return minimal_prefix(exp.expressions.first) if exp.expressions.first

      return ''
    end

    return '' unless exp.respond_to?(:expressions)

    exp.expressions.map { |child| literal_prefix(child) }.join
  end

  def representative_character(exp)
    candidates = exp.expressions.map { |child| child.text if child.is_a?(Regexp::Expression::Literal) }.compact
    candidates.concat(%w[a b c x y z 0 1 9 _ . !])
    candidates.find { |char| expression_matches?(exp, char) } || ''
  end

  def suffix_range(terms)
    return nil if terms.empty?
    [terms.first.ts, terms.last.ends_at - terms.first.ts]
  end

  def range_for(exp)
    [exp.ts, exp.full_length]
  end

  def human_class(exp)
    exp.class.name.sub('Regexp::Expression::', '')
  end

  def literal_leaf?(exp)
    exp.is_a?(Regexp::Expression::Literal) && exp.type == :literal
  end

  def anchored(source)
    ::Regexp.new('\A(?:' + source + ')\z')
  end
end
