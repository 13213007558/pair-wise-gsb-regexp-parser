# frozen_string_literal: true

class Regexp::Parser
  class FiniteLanguage
    class UnsupportedSyntaxError < Regexp::Parser::ParserError; end

    attr_reader :expression, :alphabet, :max_length

    def self.count(pattern, alphabet, max_length)
      new(pattern, alphabet, max_length).count
    end

    def self.rank(pattern, alphabet, string)
      new(pattern, alphabet, string.length).rank(string)
    end

    def self.unrank(pattern, alphabet, max_length, rank)
      new(pattern, alphabet, max_length).unrank(rank)
    end

    def self.sample(pattern, alphabet, max_length, random = nil, **options)
      random_source = options.key?(:random) ? options.fetch(:random) : random
      new(pattern, alphabet, max_length).sample(random_source)
    end

    def initialize(pattern, alphabet, max_length)
      @expression = coerce_expression(pattern)
      @alphabet = normalize_alphabet(alphabet)
      @max_length = validate_non_negative_integer(max_length, 'max_length')

      validate!(@expression)
      @graph = NfaCompiler.new(@expression, @alphabet, @max_length).compile
      @start = @graph.start
      @accept = @graph.accept
      @transitions = build_dfa
    end

    def count
      counts = { start_state => 1 }
      total = accepting?(start_state) ? 1 : 0

      @max_length.times do
        next_counts = Hash.new(0)
        counts.each do |state, state_count|
          transitions_from(state).each_value do |next_state|
            next_counts[next_state] += state_count
          end
        end
        counts = next_counts
        counts.each do |state, state_count|
          total += state_count if accepting?(state)
        end
      end

      total
    end

    def rank(string)
      validate_string(string)
      unless string.length <= @max_length
        raise ArgumentError, 'string is longer than max_length'
      end

      total = 0
      shorter = prefix_counts
      string.length.times do |length|
        shorter[length].each do |state, state_count|
          total += state_count if accepting?(state)
        end
      end

      state = start_state
      string.each_char.with_index do |char, index|
        @alphabet.each do |alphabet_char|
          break if alphabet_char == char
          next_state = transitions_from(state)[alphabet_char]
          total += suffix_count(next_state, string.length - index - 1)
        end
        next_state = transitions_from(state)[char]
        return nil unless next_state
        state = next_state
      end

      accepting?(state) ? total : nil
    end

    def unrank(rank_value)
      rank_value = validate_non_negative_integer(rank_value, 'rank')
      counts = prefix_counts
      total = 0
      length = 0

      loop do
        length_count = counts[length].inject(0) do |total, (state, state_count)|
          total + (accepting?(state) ? state_count : 0)
        end

        if rank_value < total + length_count
          rank_within_length = rank_value - total
          return unrank_within_length(length, rank_within_length)
        end

        total += length_count
        break if length == @max_length
        length += 1
      end

      raise ArgumentError, 'rank is out of range'
    end

    def sample(random = nil, **options)
      random = options.fetch(:random) if options.key?(:random)
      unless random.respond_to?(:rand)
        raise ArgumentError, 'a random source responding to #rand is required'
      end
      total = count
      raise Regexp::Parser::ParserError, 'cannot sample from an empty language' if total.zero?
      unrank(random.rand(total))
    end

    def each(&block)
      return enum_for(__method__) unless block_given?

      total = count
      total.times { |rank_value| yield(unrank(rank_value)) }
    end

    def to_a
      each.to_a
    end

    private

    def start_state
      @start_state ||= epsilon_closure([@start])
    end

    def coerce_expression(pattern)
      if pattern.is_a?(Regexp::Expression::Base)
        pattern
      else
        Regexp::Parser.parse(pattern)
      end
    end

    def normalize_alphabet(value)
      unless value.is_a?(Array) && value.all? { |char| char.is_a?(String) && char.length == 1 }
        raise ArgumentError, 'alphabet must be an Array of single-character Strings'
      end

      if value.uniq.length != value.length
        raise ArgumentError, 'alphabet must not contain duplicates'
      end

      value.dup.freeze
    end

    def validate_non_negative_integer(value, name)
      unless value.is_a?(Integer) && value >= 0
        raise ArgumentError, "#{name} must be a non-negative Integer"
      end
      value
    end

    def validate_string(string)
      unless string.is_a?(String)
        raise ArgumentError, 'string must be a String'
      end
      unless string.each_char.all? { |char| @alphabet.include?(char) }
        raise ArgumentError, 'string contains characters outside the alphabet'
      end
    end

    def validate!(expression)
      expression.each_expression(include_self: true) do |exp|
        next if exp.decorative?

        case exp
        when Regexp::Expression::Anchor::Base
          raise UnsupportedSyntaxError, 'anchors are not supported'
        when Regexp::Expression::Backreference::Base,
             Regexp::Expression::Assertion::Base,
             Regexp::Expression::Conditional::Expression,
             Regexp::Expression::Conditional::Condition,
             Regexp::Expression::Keep::Mark,
             Regexp::Expression::Group::Absence
          raise UnsupportedSyntaxError, "unsupported regular expression feature: #{exp.class}"
        when Regexp::Expression::CharacterType::ExtendedGrapheme
          raise UnsupportedSyntaxError, 'extended grapheme matching is not supported'
        end
      end
    end

    def build_dfa
      dfa = {}
      queue = [start_state]
      seen = { start_state => true }

      until queue.empty?
        state = queue.shift
        nfa_states_by_char = Hash.new { |hash, char| hash[char] = [] }

        state.each do |nfa_state|
          (@graph.char_transitions[nfa_state] || {}).each do |char, targets|
            nfa_states_by_char[char].concat(targets)
          end
        end

        @alphabet.each do |char|
          targets = nfa_states_by_char[char]
          next if targets.empty?
          next_state = epsilon_closure(targets)
          dfa[state] ||= {}
          dfa[state][char] = next_state
          unless seen.key?(next_state)
            seen[next_state] = true
            queue << next_state
          end
        end
      end

      dfa
    end

    def transitions_from(state)
      @transitions[state] ||= {}
    end

    def epsilon_closure(states)
      closure = {}
      queue = states.dup

      until queue.empty?
        state = queue.pop
        next unless closure[state].nil?
        closure[state] = true
        queue.concat(epsilon_targets(state))
      end

      closure.keys.sort
    end

    def epsilon_targets(state)
      @graph.epsilon_transitions[state] || []
    end

    def accepting?(state)
      state.include?(@accept)
    end

    def prefix_counts
      @prefix_counts ||= begin
        counts = [
          { start_state => 1 }
        ]

        @max_length.times do
          previous = counts.last
          current = Hash.new(0)
          previous.each do |state, state_count|
            transitions_from(state).each_value do |next_state|
              current[next_state] += state_count
            end
          end
          counts << current
        end

        counts
      end
    end

    def suffix_counts
      @suffix_counts ||= begin
        reachable = {}
        prefix_counts.each do |layer|
          layer.each_key { |state| reachable[state] = true }
        end

        counts = Array.new(@max_length + 1) { Hash.new }
        reachable.each_key do |state|
          counts[0][state] = accepting?(state) ? 1 : 0
        end

        (1..@max_length).each do |remaining|
          reachable.each_key do |state|
            total = transitions_from(state).inject(0) do |state_total, (_, next_state)|
              state_total + (counts[remaining - 1][next_state] || 0)
            end
            counts[remaining][state] = total
          end
        end

        counts
      end
    end

    def suffix_count(state, remaining)
      return 0 if state.nil? || remaining < 0 || remaining > @max_length
      return 1 if remaining.zero? && accepting?(state)
      return 0 if remaining.zero?
      suffix_counts[remaining][state] || 0
    end

    def unrank_within_length(length, rank_value)
      string = ''.dup
      state = start_state
      remaining = length

      while remaining > 0
        transitions_from(state).each do |char, next_state|
          state_count = suffix_count(next_state, remaining - 1)
          if rank_value < state_count
            string << char
            state = next_state
            remaining -= 1
            break
          end
          rank_value -= state_count
        end
      end

      unless accepting?(state)
        raise RuntimeError, 'internal error: unrank ended in a non-accepting state'
      end

      string
    end

    class NfaCompiler
      Graph = Struct.new(:start, :accept, :char_transitions, :epsilon_transitions)

      def initialize(expression, alphabet, max_length)
        @expression = expression
        @alphabet = alphabet
        @max_length = max_length
        @matchers = {}
        @next_state = 0
        @char_transitions = Hash.new do |transitions, state|
          transitions[state] = Hash.new { |targets, char| targets[char] = [] }
        end
        @epsilon_transitions = Hash.new { |transitions, state| transitions[state] = [] }
      end

      def compile
        start = add_state
        accept = add_state
        build_expression(@expression, start, accept)
        Graph.new(start, accept, @char_transitions, @epsilon_transitions)
      end

      private

      def add_state
        state = @next_state
        @next_state += 1
        state
      end

      def connect(start, target)
        @epsilon_transitions[start] << target
      end

      def connect_char(start, char, target)
        @char_transitions[start][char] << target
      end

      def build_expression(exp, start, accept)
        return if exp.decorative?

        if exp.quantified?
          build_quantified(exp, start, accept)
        else
          build_unquantified(exp, start, accept)
        end
      end

      def build_quantified(exp, start, accept)
        min = exp.quantifier.min
        max = exp.quantifier.max < 0 ? nil : exp.quantifier.max
        base_min_length = unquantified_minimum_length(exp)

        return if base_min_length > 0 && min > @max_length
        return connect(start, accept) if max == 0

        effective_min = base_min_length > 0 ? min : [min, @max_length + 1].min
        effective_max = max.nil? ? nil : [max, @max_length + (base_min_length.zero? ? 1 : 0)].min
        return connect(start, accept) if effective_max == 0

        current = start
        effective_min.times do
          current = append_base(exp, current)
        end

        if max.nil?
          junction = add_state
          connect(current, junction)
          base_start = add_state
          base_accept = add_state
          connect(junction, base_start)
          build_unquantified(exp, base_start, base_accept)
          connect(base_accept, junction)
          connect(junction, accept)
        else
          (effective_max - effective_min).times do
            base_start = add_state
            base_accept = add_state
            next_state = add_state
            connect(current, next_state)
            connect(current, base_start)
            build_unquantified(exp, base_start, base_accept)
            connect(base_accept, next_state)
            current = next_state
          end
          connect(current, accept)
        end
      end

      def append_base(exp, current)
        base_start = add_state
        base_accept = add_state
        connect(current, base_start)
        build_unquantified(exp, base_start, base_accept)
        base_accept
      end

      def build_unquantified(exp, start, accept)
        case exp
        when Regexp::Expression::Alternation
          exp.each do |alternative|
            alternative_start = add_state
            alternative_accept = add_state
            connect(start, alternative_start)
            build_sequence(alternative, alternative_start, alternative_accept)
            connect(alternative_accept, accept)
          end
        when Regexp::Expression::CharacterSet
          build_character_predicate(exp, start, accept)
        when Regexp::Expression::Subexpression
          build_sequence(exp, start, accept)
        when Regexp::Expression::Literal,
             Regexp::Expression::EscapeSequence::Base,
             Regexp::Expression::CharacterType::Base,
             Regexp::Expression::PosixClass,
             Regexp::Expression::UnicodeProperty::Base
          build_character_predicate(exp, start, accept)
        else
          raise FiniteLanguage::UnsupportedSyntaxError,
                "unsupported regular expression feature: #{exp.class}"
        end
      end

      def build_sequence(container, start, accept)
        current = start
        children = container.reject(&:decorative?)

        children.each do |child|
          child_start = add_state
          child_accept = add_state
          connect(current, child_start)
          build_expression(child, child_start, child_accept)
          current = child_accept
        end

        connect(current, accept)
      end

      def build_character_predicate(exp, start, accept)
        if exp.is_a?(Regexp::Expression::CharacterSet) ||
           exp.is_a?(Regexp::Expression::CharacterType::Base) ||
           exp.is_a?(Regexp::Expression::PosixClass) ||
           exp.is_a?(Regexp::Expression::UnicodeProperty::Base)
          predicate_chars(exp).each { |char| connect_char(start, char, accept) }
        else
          literal_sequences(exp).each do |positions|
            current = start
            positions.each_with_index do |chars, index|
              target = index == positions.length - 1 ? accept : add_state
              chars.each { |char| connect_char(current, char, target) }
              current = target
            end
          end
        end
      end

      def predicate_chars(exp)
        @alphabet.select { |char| atom_match?(exp, predicate_source(exp), char) }
      end

      def literal_sequences(exp)
        case exp
        when Regexp::Expression::Literal
          literal_sequence(exp, exp.text.each_char.to_a)
        when Regexp::Expression::EscapeSequence::CodepointList
          literal_sequence(exp, exp.chars)
        when Regexp::Expression::EscapeSequence::Base
          chars = matching_alphabet_chars(exp, exp.char)
          chars.empty? ? [] : [chars]
        end
      end

      def literal_sequence(exp, chars)
        positions = chars.map { |char| matching_alphabet_chars(exp, char) }
        positions.any?(&:empty?) ? [] : [positions]
      end

      def matching_alphabet_chars(exp, literal_char)
        source = Regexp.escape(literal_char)
        @alphabet.select { |alphabet_char| atom_match?(exp, source, alphabet_char) }
      end

      def predicate_source(exp)
        if exp.is_a?(Regexp::Expression::PosixClass)
          "[#{exp.to_s(:base)}]"
        else
          exp.to_s(:base)
        end
      end

      def atom_match?(exp, source, char)
        flags = option_flags(exp)
        matcher = @matchers[[source, flags]] ||=
          Regexp.new("\\A(?:#{source})\\z", flags)
        matcher.match?(char)
      rescue RegexpError
        raise FiniteLanguage::UnsupportedSyntaxError,
              "unsupported character predicate: #{exp.to_s(:base)}"
      end

      def option_flags(exp)
        flags = 0
        flags |= Regexp::IGNORECASE if exp.case_insensitive?
        flags |= Regexp::MULTILINE if exp.multiline?
        flags
      end

      def minimum_length(exp)
        return unquantified_minimum_length(exp) * exp.quantifier.min if exp.quantified?
        unquantified_minimum_length(exp)
      end

      def unquantified_minimum_length(exp)
        case exp
        when Regexp::Expression::Alternation
          exp.map { |alternative| minimum_length(alternative) }.min
        when Regexp::Expression::Literal
          possible_literal_length(exp, exp.text.each_char.to_a, exp.text.length)
        when Regexp::Expression::EscapeSequence::CodepointList
          possible_literal_length(exp, exp.chars, exp.chars.length)
        when Regexp::Expression::EscapeSequence::Base
          matching_alphabet_chars(exp, exp.char).empty? ? 0 : 1
        when Regexp::Expression::CharacterSet,
             Regexp::Expression::CharacterType::Base,
             Regexp::Expression::PosixClass,
             Regexp::Expression::UnicodeProperty::Base
          1
        when Regexp::Expression::Subexpression
          exp.reject(&:decorative?).sum { |child| minimum_length(child) }
        else
          0
        end
      end

      def possible_literal_length(exp, chars, default_length)
        positions = chars.map { |char| matching_alphabet_chars(exp, char) }
        positions.any?(&:empty?) ? 0 : default_length
      end
    end
  end
end
