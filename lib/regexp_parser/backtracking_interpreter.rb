# frozen_string_literal: true

class Regexp::Parser
  # A deliberately small backtracking interpreter. It is used by the static
  # analysis instead of wall-clock benchmarks.
  class BacktrackingInterpreter
    class UnsupportedFeature < StandardError; end
    class StepLimitReached < StandardError
      attr_reader :steps

      def initialize(steps)
        @steps = steps
        super('step limit reached')
      end
    end

    attr_reader :steps

    def initialize(step_limit: nil)
      @step_limit = step_limit
      @steps = 0
      @leaf_patterns = {}
    end

    def self.match?(root, string, step_limit: nil)
      new(step_limit: step_limit).match?(root, string)
    end

    def match?(root, string)
      !count_matches(root, string, 1).zero?
    end

    def failure_steps(root, string)
      count = count_matches(root, string, 1)
      count.zero? ? steps : nil
    rescue StepLimitReached => error
      error.steps
    end

    def match_count(exp, string, limit = nil)
      matches = []
      catch(:stop_counting) do
        enumerate_expression(exp, string, 0) do |position|
          if position == string.length
            matches << position
            throw :stop_counting if limit && matches.length >= limit
          end
        end
      end
      matches.length
    end

    def sequence_match?(expressions, string, exact: false)
      matched = false
      catch(:stop_sequence_match) do
        enumerate_sequence(expressions, string, 0) do |position|
          if !exact || position == string.length
            matched = true
            throw :stop_sequence_match
          end
        end
      end
      matched
    end

    def match_at?(exp, string, position)
      matched = false
      catch(:stop_match_at) do
        enumerate_expression(exp, string, position) do
          matched = true
          throw :stop_match_at
        end
      end
      matched
    end

    def positive_end_positions(exp, string, limit = 8)
      positive_end_position_counts(exp, string, limit).keys.sort
    end

    def positive_end_position_counts(exp, string, limit = 8)
      counts = Hash.new(0)
      catch(:stop_positive_positions) do
        enumerate_expression(exp, string, 0) do |position|
          if position.positive?
            counts[position] += 1
            throw :stop_positive_positions if counts.length >= limit &&
                                               counts.values.all? { |value| value >= limit }
          end
        end
      end
      counts
    end

    def first_match_length(exp, string, position = 0)
      result = nil
      catch(:stop_enumeration) do
        enumerate_expression(exp, string, position) do |stop_position|
          result = stop_position - position
          throw :stop_enumeration
        end
      end
      result
    end

    private

    def count_matches(root, string, limit)
      count = 0
      catch(:stop_enumeration) do
        start_positions(root, string).each do |position|
          enumerate_children(root, string, position) do |stop_position|
            exact = position.zero? && anchored_root?(root)
            if !exact || stop_position == string.length
              count += 1
              throw :stop_enumeration if count >= limit
            end
          end
        end
      end
      count
    end

    def start_positions(root, string)
      first = root.expressions.first
      if first.is_a?(Regexp::Expression::Anchor::BeginningOfString)
        [0]
      else
        (0..string.length).to_a
      end
    end

    def anchored_root?(root)
      first = root.expressions.first
      first.is_a?(Regexp::Expression::Anchor::BeginningOfString)
    end

    def enumerate_expression(exp, string, position, &block)
      case exp
      when ->(node) { node.respond_to?(:quantified?) && node.quantified? }
        enumerate_quantified(exp, string, position, &block)
      when Regexp::Expression::Alternation
        enumerate_alternation(exp, string, position, &block)
      when Regexp::Expression::Group::Atomic
        enumerate_atomic(exp, string, position, &block)
      when Regexp::Expression::CharacterSet
        enumerate_leaf(exp, string, position, &block)
      when Regexp::Expression::Subexpression
        enumerate_subexpression(exp, string, position, &block)
      else
        enumerate_terminal(exp, string, position, &block)
      end
    end

    def enumerate_subexpression(exp, string, position, &block)
      if exp.quantified?
        enumerate_quantified(exp, string, position, &block)
      else
        enumerate_children(exp, string, position, &block)
      end
    end

    def enumerate_children(exp, string, position, &block)
      enumerate_sequence(exp.expressions, string, position, &block)
    end

    def enumerate_sequence(expressions, string, position, &block)
      if expressions.empty?
        yield(position)
        return
      end

      first, *remaining = expressions
      enumerate_expression(first, string, position) do |next_position|
        enumerate_sequence(remaining, string, next_position, &block)
      end
    end

    def enumerate_alternation(exp, string, position, &block)
      exp.alternatives.each do |alternative|
        enumerate_children(alternative, string, position, &block)
      end
    end

    def enumerate_atomic(exp, string, position, &block)
      if exp.quantified?
        enumerate_quantified(exp, string, position, &block)
        return
      end

      enumerate_atomic_body(exp, string, position, &block)
    end

    def enumerate_atomic_body(exp, string, position, &block)
      committed = catch(:atomic_commit) do
        enumerate_children(exp, string, position) do |next_position|
          throw :atomic_commit, next_position
        end
        :no_match
      end
      yield(committed) unless committed == :no_match
    end

    def enumerate_quantified(exp, string, position, &block)
      target = quantified_target(exp)
      min = exp.quantifier.min
      max = normalized_max(exp.quantifier.max)
      mode = exp.quantifier.mode

      enumerate_body = lambda do |start, last_position, continuation|
        allow_empty = last_position.nil? || start != last_position
        each_body_match(target, string, start) do |next_position|
          next if !allow_empty && next_position == start
          continuation.call(next_position)
        end
      end

      if mode == :possessive
        enumerate_possessive(target, string, position, min, max, enumerate_body, &block)
      elsif mode == :reluctant
        enumerate_lazy(target, string, position, min, max, enumerate_body, &block)
      else
        enumerate_greedy(target, string, position, min, max, enumerate_body, &block)
      end
    end

    def quantified_target(exp)
      exp.is_a?(Regexp::Expression::CharacterSet) ? exp : exp
    end

    def each_body_match(target, string, position, &block)
      case target
      when Regexp::Expression::Alternation
        enumerate_alternation(target, string, position, &block)
      when Regexp::Expression::Group::Atomic
        enumerate_atomic_body(target, string, position, &block)
      when Regexp::Expression::CharacterSet
        enumerate_leaf(target, string, position, &block)
      when Regexp::Expression::Subexpression
        enumerate_children(target, string, position, &block)
      else
        enumerate_terminal(target, string, position, &block)
      end
    end

    def enumerate_greedy(_target, _string, position, min, max, body, &block)
      visit = lambda do |count, current, last_position|
        if count < max
          body.call(current, last_position, lambda do |next_position|
            visit.call(count + 1, next_position, current)
          end)
        end
        yield(current) if count >= min
      end
      visit.call(0, position, nil)
    end

    def enumerate_lazy(_target, _string, position, min, max, body, &block)
      visit = lambda do |count, current, last_position|
        yield(current) if count >= min
        return if count >= max

        body.call(current, last_position, lambda do |next_position|
          visit.call(count + 1, next_position, current)
        end)
      end
      visit.call(0, position, nil)
    end

    def enumerate_possessive(_target, _string, position, min, max, body)
      count = 0
      current = position
      last_position = nil

      while count < max
        next_position = catch(:possessive_choice) do
          body.call(current, last_position, lambda do |candidate|
            throw :possessive_choice, candidate
          end)
          nil
        end
        break if next_position.nil? || next_position == current

        count += 1
        last_position = current
        current = next_position
      end

      yield(current) if count >= min
    end

    def enumerate_terminal(exp, string, position, &block)
      if exp.is_a?(Regexp::Expression::Anchor::Base)
        enumerate_anchor(exp, string, position, &block)
      elsif exp.comment? || exp.is_a?(Regexp::Expression::FreeSpace)
        yield(position)
      elsif leaf?(exp)
        enumerate_leaf(exp, string, position, &block)
      else
        raise UnsupportedFeature, "#{exp.class} at #{position_label(exp)}"
      end
    end

    def enumerate_anchor(exp, string, position, &block)
      matched = case exp
                when Regexp::Expression::Anchor::BeginningOfString
                  position.zero?
                when Regexp::Expression::Anchor::BeginningOfLine
                  position.zero? || string[position - 1] == "\n"
                when Regexp::Expression::Anchor::EndOfString
                  position == string.length
                when Regexp::Expression::Anchor::EndOfStringOrBeforeEndOfLine,
                     Regexp::Expression::Anchor::EndOfLine
                  position == string.length ||
                    (position == string.length - 1 && string[position] == "\n")
                else
                  raise UnsupportedFeature, "#{exp.class} at #{position_label(exp)}"
                end
      yield(position) if matched
    end

    def enumerate_leaf(exp, string, position, &block)
      count_step!
      text = leaf_match_text(exp, string, position)
      yield(position + text.length) if text
    end

    def leaf_match_text(exp, string, position)
      pattern = leaf_pattern(exp)
      match = pattern.match(string[position..-1].to_s)
      match && match[0]
    end

    def leaf_pattern(exp)
      @leaf_patterns[[exp.class, exp.to_s(:base), exp.options]] ||=
        ::Regexp.new('\\A(?:' + exp.to_s(:base) + ')',
                     options_to_flags(exp.options))
    rescue RegexpError
      raise UnsupportedFeature, "unsupported leaf #{exp.to_s(:base).inspect}"
    end

    def options_to_flags(options)
      flags = 0
      flags |= Regexp::IGNORECASE if options[:i]
      flags |= Regexp::MULTILINE if options[:m]
      flags |= Regexp::EXTENDED if options[:x]
      flags
    end

    def leaf?(exp)
      exp.terminal? && !exp.decorative? &&
        !exp.is_a?(Regexp::Expression::Anchor::Base)
    end

    def count_step!
      @steps += 1
      raise StepLimitReached.new(@steps) if @step_limit && @steps > @step_limit
    end

    def normalized_max(max)
      max < 0 ? Float::INFINITY : max
    end

    def position_label(exp)
      "@#{exp.starts_at}+#{exp.full_length}"
    end
  end
end
