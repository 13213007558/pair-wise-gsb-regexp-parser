# frozen_string_literal: true

require_relative 'backtracking_interpreter'

class Regexp::Parser
  class BacktrackingStaticAnalyzer
    class UnsupportedFeature < StandardError; end

    Result = Struct.new(:status, :findings)
    Finding = Struct.new(
      :severity, :message, :starts_at, :length, :ast_path,
      :prefix, :repeat, :failing_suffix, :measurements,
      :locations
    )

    def self.analyze(pattern, sizes: [6, 8, 10, 12], step_limit: 2_000_000)
      root = pattern.is_a?(Regexp::Expression::Base) ? pattern : Regexp::Parser.parse(pattern)
      new(sizes: sizes, step_limit: step_limit).analyze(root)
    end

    def initialize(sizes: [6, 8, 10, 12], step_limit: 2_000_000)
      @sizes = sizes
      @step_limit = step_limit
      @findings = []
      @candidate_count = 0
      @verified_candidate_count = 0
    end

    def analyze(root)
      @root = root
      verify_supported(root)
      if @sizes.length < 3
        raise UnsupportedFeature, 'at least three input sizes are required to verify growth'
      end
      scan_sequence(root, 0, [], '', '', !anchored_container?(root))
      dedupe_findings
      if @findings.any?
        Result.new(:unsafe, @findings)
      elsif @verified_candidate_count == @candidate_count
        Result.new(:safe, [])
      else
        Result.new(:unknown, [unknown_finding(root, 'unable to construct a reviewable witness')])
      end
    rescue UnsupportedFeature, BacktrackingInterpreter::UnsupportedFeature => error
      Result.new(:unknown, [unknown_finding(root, error.message)])
    end

    def dedupe_findings
      @findings = @findings.group_by do |finding|
        [finding.prefix, finding.repeat, finding.failing_suffix]
      end.values.map do |group|
        first = group.max_by { |finding| severity_rank(finding.severity) }
        first.locations = group.map do |finding|
          { starts_at: finding.starts_at, length: finding.length, ast_path: finding.ast_path }
        end.uniq
        first
      end
    end

    def severity_rank(severity)
      { unknown: 0, polynomial: 1, exponential: 2 }.fetch(severity, 0)
    end

    private

    def verify_supported(exp)
      case exp
      when Regexp::Expression::Backreference::Base,
           Regexp::Expression::Conditional::Expression,
           Regexp::Expression::Conditional::Condition,
           Regexp::Expression::Group::Absence,
           Regexp::Expression::Assertion::Base
        unsupported(exp, 'backreference, recursive call, conditional, assertion, or absence group')
      when Regexp::Expression::Anchor::WordBoundary,
           Regexp::Expression::Anchor::NonWordBoundary,
           Regexp::Expression::Anchor::MatchStart,
           Regexp::Expression::Anchor::EndOfLine,
           Regexp::Expression::Anchor::EndOfStringOrBeforeEndOfLine
        unsupported(exp, 'unsupported anchor')
      when Regexp::Expression::CharacterSet::Intersection
        unsupported(exp, 'character set intersection')
      when Regexp::Expression::Subexpression
        exp.each { |child| verify_supported(child) }
      end
    end

    def scan_sequence(container, start_index, path, full_prefix, prefix_fragment, searchable)
      analyze_sequence_children(
        container, start_index, path,
        full_prefix, prefix_fragment, searchable
      )

      container.each_with_index do |child, index|
        next if index < start_index

        child_path = path + [index]
        child_prefix_fragment = collect_prefix(container, index, prefix_fragment).first
        next if child_prefix_fragment.nil?
        child_full_prefix = full_prefix + child_prefix_fragment

        if child.is_a?(Regexp::Expression::Group::Atomic) ||
           (child.quantified? && child.quantifier.possessive?)
          scan_isolated(child, child_path)
        elsif child.is_a?(Regexp::Expression::Alternation)
          scan_alternation(child, child_path, full_prefix, child_prefix_fragment, searchable)
        elsif sequence_container?(child)
          scan_sequence(child, 0, child_path, child_full_prefix, '', false)
        end
      end
    end

    def scan_alternation(alternation, path, full_prefix, prefix_fragment, searchable)
      alternation.alternatives.each_with_index do |alternative, index|
        scan_sequence(
          alternative, 0, path + [index],
          full_prefix, prefix_fragment, child_searchable(searchable, prefix_fragment)
        )
      end
    end

    def scan_isolated(container, path)
      return unless sequence_container?(container)

      analyze_sequence_children(container, 0, path, '', '', false)
      container.each_with_index do |child, index|
        child_path = path + [index]
        if child.is_a?(Regexp::Expression::Group::Atomic) ||
           (child.quantified? && child.quantifier.possessive?)
          scan_isolated(child, child_path)
        elsif child.is_a?(Regexp::Expression::Alternation)
          scan_alternation(child, child_path, '', '', false)
        elsif sequence_container?(child)
          prefix = collect_prefix(container, index, '').first
          scan_sequence(child, 0, child_path, prefix || '', '', false) if prefix
        end
      end
    end

    def sequence_container?(exp)
      exp.is_a?(Regexp::Expression::Subexpression) &&
        !exp.is_a?(Regexp::Expression::Alternation)
    end

    def analyze_sequence_children(container, start_index, path,
                                 full_prefix, prefix_fragment, searchable)
      container.each_with_index do |child, index|
        next if index < start_index
        child_path = path + [index]
        local_prefixes = collect_prefix(container, index, prefix_fragment)
        next if local_prefixes.empty?
        prefix_word = full_prefix + local_prefixes.first

        repeat_candidates(child, child_path).each do |candidate|
          repeat = candidate[:repeat]
          failing_suffix = failing_suffix_for(container, index + 1, repeat)
          next unless failing_suffix
          @candidate_count += 1

          reported = false
          report_if_growing(
            container, candidate[:exp], candidate[:path],
            prefix_word, repeat, failing_suffix, searchable
          ) do |finding|
            @findings << finding
            reported = true
          end
          break if reported
        end
      end
    end

    def collect_prefix(container, index, inherited_prefix)
      prefixes = inherited_prefix.empty? ? [''] : [inherited_prefix]
      container[0...index].each do |previous|
        prefixes = append_prefixes(prefixes, previous)
        return [] if prefixes.empty?
      end
      prefixes
    end

    def append_prefixes(prefixes, exp)
      options = prefix_options(exp)
      return prefixes if options.empty?
      prefixes.product(options).map { |prefix, suffix| prefix + suffix }
    end

    def prefix_options(exp)
      if exp.comment? || exp.is_a?(Regexp::Expression::FreeSpace) ||
         exp.is_a?(Regexp::Expression::Group::Options) ||
         exp.is_a?(Regexp::Expression::Anchor::Base) ||
         exp.is_a?(Regexp::Expression::Keep::Mark)
        return ['']
      end

      if quantified_zero?(exp)
        return ['']
      elsif exp.quantified?
        min = exp.quantifier.min
        return [''] if min.zero?
        base = unquantified_expression(exp)
        options = base.is_a?(Regexp::Expression::Subexpression) ?
          options_for_children(base) : leaf_pieces(base)
        options.map { |piece| piece * min }
      elsif exp.is_a?(Regexp::Expression::Group::Atomic)
        options_for_children(exp)
      elsif exp.is_a?(Regexp::Expression::Alternation)
        exp.alternatives.map { |branch| option_for_children(branch) }.compact
      elsif exp.is_a?(Regexp::Expression::Subexpression)
        options_for_children(exp)
      else
        leaf_pieces(exp)
      end
    end

    def options_for_children(container)
      options = ['']
      container.each do |child|
        child_options = prefix_options(child)
        return [] if child_options.empty?
        options = options.product(child_options).map { |left, right| left + right }
        return [] if options.length > 8
      end
      options
    end

    def option_for_children(container)
      option = ''
      container.each do |child|
        child_options = prefix_options(child)
        return nil if child_options.empty?
        option += child_options.first
      end
      option
    end

    def quantified_zero?(exp)
      exp.quantified? && exp.quantifier.max == 0
    end

    def repeat_candidates(exp, path)
      if repeatable?(exp)
        return simple_repeat(exp).map do |repeat|
          { repeat: repeat, exp: exp, path: path }
        end
      end
      nested_repeat_candidates(exp, path)
    end

    def nested_repeat_candidates(exp, path)
      return [] unless transparent_container?(exp)

      candidates = []
      expressions_with_paths(exp).each do |child, child_path|
        next if child.is_a?(Regexp::Expression::Group::Atomic)
        next if child.quantified? && child.quantifier.possessive?

        if repeatable?(child)
          simple_repeat(child).each do |repeat|
            candidates << { repeat: repeat, exp: child, path: path + [child_path] }
          end
        else
          candidates.concat(nested_repeat_candidates(child, path + [child_path]))
        end
      end
      candidates.uniq { |candidate| [candidate[:repeat], candidate[:path]] }
    end

    def transparent_container?(exp)
      (exp.is_a?(Regexp::Expression::Group::Base) &&
        !exp.is_a?(Regexp::Expression::Group::Atomic)) ||
        exp.is_a?(Regexp::Expression::Alternative)
    end

    def expressions_with_paths(exp)
      if exp.is_a?(Regexp::Expression::Alternation)
        exp.alternatives.each_with_index.to_a
      else
        exp.each_with_index.to_a
      end
    end

    def repeatable?(exp)
      exp.quantified? &&
        !exp.quantifier.possessive? &&
        !exp.is_a?(Regexp::Expression::Group::Atomic)
    end

    def simple_repeat(exp)
      quantifier = exp.quantifier
      return [] if quantifier.max == 0 || quantifier.max == 1

      candidates_for(exp).select do |repeat|
        body = unquantified_expression(exp)
        interpreter.match_at?(body, repeat, 0)
      end
    end

    def candidates_for(exp)
      candidates = []
      collect_leaf_words(unquantified_expression(exp), candidates)
      candidates.uniq.first(24)
    end

    def collect_leaf_words(exp, candidates)
      case exp
      when Regexp::Expression::CharacterSet
        leaf_pieces(exp).each { |piece| candidates << piece }
      when Regexp::Expression::Alternation
        exp.alternatives.each { |branch| collect_leaf_words(branch, candidates) }
      when Regexp::Expression::Subexpression
        exp.each { |child| collect_leaf_words(child, candidates) }
      when Regexp::Expression::Anchor::Base,
           Regexp::Expression::FreeSpace,
           Regexp::Expression::Keep::Mark
        nil
      else
        leaf_pieces(exp).each do |piece|
          candidates << piece
          candidates.concat(piece.chars)
        end
      end
    end

    def leaf_pieces(exp)
      if exp.is_a?(Regexp::Expression::Literal)
        return [exp.to_s(:base)].reject(&:empty?)
      end

      if exp.respond_to?(:chars)
        pieces = exp.chars
        return [pieces.join] unless pieces.empty?
      elsif exp.respond_to?(:char)
        return [exp.char]
      end

      sample = sample_for_leaf(exp)
      sample ? [sample] : []
    end

    def sample_for_leaf(exp)
      characters = (0x21..0x7e).map { |code| code.chr(Encoding::UTF_8) }
      characters << "\t" << "\n"
      characters.find { |character| interpreter.match_at?(exp, character, 0) }
    end

    def unquantified_expression(exp)
      exp.unquantified_clone
    end

    def failing_suffix_for(container, start_index, repeat)
      has_anchor = container[start_index..-1].any? do |exp|
        exp.is_a?(Regexp::Expression::Anchor::EndOfString)
      end
      suffix_candidates(has_anchor).find do |suffix|
        !remainder_matches?(container[start_index..-1], repeat, suffix)
      end
    end

    def suffix_candidates(has_anchor)
      if has_anchor
        ['!', '"', '#', '%', '&', "'", ')', '*', '+', ',', '-', '.', '/',
         ':', ';', '<', '=', '>', '?', '@', '\\', ']', '^', '_', '`', '{',
         '|', '}', '~', "\t", "\n", 'a', 'A', '0']
      else
        ['!', '"', '#', '%', '&', "'", ')', ',', '-', '.', '/', ':', ';',
         '<', '>', '@', '\\', ']', '^', '_', '`', '{', '|', '}', '~']
      end
    end

    def remainder_matches?(expressions, repeat, suffix)
      interpreter.sequence_match?(expressions, repeat + suffix, exact: true) ||
        interpreter.sequence_match?(expressions, suffix, exact: true)
    end

    def report_if_growing(container, exp, path, prefix, repeat, failing_suffix, searchable)
      expected = expected_severity(container, exp, repeat, prefix, searchable)
      measurements = measure(prefix, repeat, failing_suffix)
      @verified_candidate_count += 1
      return unless expected && !measurements.empty? && growth_confirmed?(expected, measurements)

      severity = expected
      finding = Finding.new(severity, message_for(severity, exp), exp.starts_at,
                            exp.full_length, path, prefix, repeat, failing_suffix,
                            measurements, nil)
      yield(finding) if block_given?
      finding
    end

    def measure(prefix, repeat, failing_suffix)
      @sizes.map do |size|
        input = prefix + repeat * size + failing_suffix
        steps = interpreter_for_measurement.failure_steps(@root, input)
        steps ? { size: size, steps: steps, input: input } : nil
      end.compact
    end

    def expected_severity(container, exp, repeat, prefix, searchable)
      if exponential_quantifier?(exp, repeat)
        :exponential
      elsif polynomial_quantifier?(container, exp, repeat, prefix, searchable)
        :polynomial
      end
    end

    def exponential_quantifier?(exp, repeat)
      return false unless exp.quantified? && !exp.quantifier.possessive?
      return false unless exp.quantifier.max < 0

      body = unquantified_expression(exp)
      return true unless open_quantifiers_for(body, repeat).empty?
      return true if interpreter.match_at?(body, '', 0)

      counts = positive_position_counts(body, repeat * 4)
      positions = counts.keys
      counts.values.any? { |count| count >= 2 } ||
        (positions.length >= 2 && gcd(positions) == repeat.length)
    end

    def polynomial_quantifier?(container, exp, repeat, prefix, searchable)
      degree = if exp.quantifier.max >= 0
                 open_quantifiers_for(unquantified_expression(exp), repeat).uniq.length
      else
        compatible_quantifiers(container, repeat).uniq.length
      end
      degree += 1 if searchable
      degree >= 1
    end

    def open_quantifiers_for(exp, repeat)
      each_quantified(exp).select do |candidate|
        next false if candidate.quantifier.possessive?
        next false if candidate.is_a?(Regexp::Expression::Group::Atomic)
        next false unless candidate.quantifier.max < 0

        interpreter.match_at?(unquantified_expression(candidate), repeat, 0)
      end
    end

    def positive_position_counts(exp, string)
      BacktrackingInterpreter.new(step_limit: @step_limit)
                           .positive_end_position_counts(exp, string, 8)
    end

    def compatible_quantifiers(container, repeat)
      return [] unless container.respond_to?(:each)
      quantifiers = []
      container.each do |child|
        next unless child.respond_to?(:quantified?) && child.quantified?
        next if child.quantifier.possessive?
        next if child.is_a?(Regexp::Expression::Group::Atomic)
        next unless interpreter.match_at?(unquantified_expression(child), repeat, 0)
        add_compatible_quantifier(quantifiers, child, repeat)
      end
      quantifiers
    end

    def add_compatible_quantifier(quantifiers, exp, repeat)
      quantifiers << exp
      body = unquantified_expression(exp)
      collect_nested_compatible_quantifiers(body, repeat, quantifiers)
    end

    def collect_nested_compatible_quantifiers(exp, repeat, quantifiers)
      return unless transparent_container?(exp)

      exp.each do |child|
        next if child.is_a?(Regexp::Expression::Group::Atomic)
        next if child.quantified? && child.quantifier.possessive?

        if child.quantified? && interpreter.match_at?(unquantified_expression(child), repeat, 0)
          quantifiers << child
        end
        collect_nested_compatible_quantifiers(child, repeat, quantifiers)
      end
    end

    def each_quantified(exp, &block)
      return enum_for(__method__, exp) unless block
      return unless exp.respond_to?(:each)

      exp.each do |child|
        if child.respond_to?(:quantified?) && child.quantified?
          yield(child)
          next
        end
        next if child.is_a?(Regexp::Expression::Group::Atomic)
        next if child.respond_to?(:quantified?) && child.quantified? && child.quantifier.possessive?

        each_quantified(child, &block)
      end
    end

    def anchored_container?(container)
      first = container.respond_to?(:first) ? container.first : nil
      first.is_a?(Regexp::Expression::Anchor::BeginningOfString) ||
        first.is_a?(Regexp::Expression::Anchor::BeginningOfLine)
    end

    def child_searchable(searchable, prefix)
      searchable && prefix.to_s.empty?
    end

    def gcd(values)
      values.inject(0) { |result, value| result.gcd(value) }
    end

    def growth_confirmed?(expected, measurements)
      values = measurements.map { |measurement| measurement[:steps] }
      sizes = measurements.map { |measurement| measurement[:size] }
      return false if values.length < 3

      case expected
      when :exponential
        values.each_cons(2).zip(sizes.each_cons(2)).any? do |(left, right), (small, large)|
          ratio = right.to_f / left
          ratio > 1.45 && ratio > 1 + 1.0 / (large - small)
        end
      when :polynomial
        degrees = values.each_cons(2).zip(sizes.each_cons(2)).map do |(left, right), (small, large)|
          Math.log(right.to_f / left) / Math.log(large.to_f / small)
        end
        degrees.last(2).all? { |degree| degree > 1.35 }
      end
    end

    def message_for(severity, exp)
      kind = exp.quantifier ? 'quantified expression' : 'nested ambiguous expression'
      "#{severity} backtracking growth from #{kind} at #{location(exp)}"
    end

    def interpreter
      @interpreter ||= BacktrackingInterpreter.new(step_limit: @step_limit)
    end

    def interpreter_for_measurement
      BacktrackingInterpreter.new(step_limit: @step_limit)
    end

    def unknown_finding(root, reason)
      Finding.new(
        :unknown,
        "Unable to determine backtracking behavior: #{reason}",
        root.starts_at,
        root.full_length,
        [],
        nil,
        nil,
        nil,
        nil,
        nil
      )
    end

    def unsupported(exp, what)
      raise UnsupportedFeature, "#{what} is outside the supported subset at #{location(exp)}"
    end

    def location(exp)
      "@#{exp.starts_at}+#{exp.full_length}"
    end
  end
end
