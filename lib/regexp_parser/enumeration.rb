# frozen_string_literal: true

class Regexp::Parser
  # Counts, ranks, un-ranks, and uniformly samples the *distinct* strings
  # over a caller-supplied finite, ordered alphabet that a regular expression
  # matches as a whole (like /\A(?:pattern)\z/) within a given length bound.
  #
  # Only a plain regular subset is supported: literals, escape sequences,
  # character sets/types, unicode properties, alternation, groups (capturing,
  # non-capturing, named, option groups/switches), comments, and quantifiers
  # of any mode (greedy, reluctant, possessive - the mode does not change the
  # matched language). The anchors ^, $, \A and \z are accepted as no-ops
  # because matching is always anchored to the whole string.
  #
  # Backreferences, subexpression calls and recursion, lookaround assertions,
  # conditionals, atomic groups, the absence operator, \K, context-dependent
  # anchors (\b, \B, \G, \Z), and variable-length atoms (\R, \X, \u{... ...})
  # are rejected with UnsupportedExpressionError.
  #
  # Strings are ordered by length first, then by the alphabet's order. Every
  # distinct string is counted exactly once, no matter how many alternatives
  # or parse paths match it, because the expression is determinized into a
  # DFA before counting. All counts are arbitrary-precision Integers.
  #
  #   enum = Regexp::Parser::Enumeration.new('(ab|a)c?', alphabet: %w[a b c], max_length: 3)
  #   enum.count                    # => 4
  #   enum.unrank(0)                # => "a"
  #   enum.rank('abc')              # => 3
  #   enum.sample(random: Random.new(42)) # => uniformly random distinct string
  class Enumeration
    # Raised when the pattern uses an expression outside the supported subset.
    UnsupportedExpressionError = Class.new(Regexp::Parser::Error)

    attr_reader :alphabet, :min_length, :max_length

    def initialize(source, alphabet:, max_length:, min_length: 0)
      root = source.is_a?(Regexp::Expression::Base) ? source : Regexp::Parser.parse(source)
      @alphabet   = normalize_alphabet(alphabet)
      @min_length = validate_length(:min_length, min_length)
      @max_length = validate_length(:max_length, max_length)
      if @max_length < @min_length
        raise ArgumentError, "max_length (#{@max_length}) must be >= min_length (#{@min_length})"
      end
      @alphabet_index = @alphabet.each_with_index.to_h

      dfa = Automaton.new(root, @alphabet)
      @start       = dfa.start
      @transitions = dfa.transitions
      @accepting   = dfa.accepting
      @exact       = build_count_table
    end

    # The number of distinct strings with min_length <= length <= max_length.
    def count
      @count ||= (@min_length..@max_length).inject(0) { |sum, len| sum + @exact[@start][len] }
    end

    # True if +string+ is part of the enumeration.
    def include?(string)
      !rank(string).nil?
    end

    # The 0-based position of +string+ in the enumeration, or nil if the
    # string uses characters outside the alphabet, violates the length
    # bounds, or is not matched.
    def rank(string)
      chars = String(string).chars
      return nil if chars.length < @min_length || chars.length > @max_length

      indices = chars.map { |char| @alphabet_index[char] or return nil }
      index = (@min_length...chars.length).inject(0) { |sum, len| sum + @exact[@start][len] }
      state = @start
      indices.each_with_index do |char_index, pos|
        remaining = chars.length - pos - 1
        row = @transitions[state]
        char_index.times do |ci|
          target = row[ci]
          index += @exact[target][remaining] if target
        end
        state = row[char_index] or return nil
      end
      @accepting[state] ? index : nil
    end

    # The string at 0-based +index+. Raises IndexError if out of range.
    def unrank(index)
      index = Integer(index)
      total = count
      raise IndexError, "index #{index} outside of 0...#{total}" if index < 0 || index >= total

      length = @min_length
      length += 1 while index >= (amount = @exact[@start][length]) && (index -= amount)

      state = @start
      chars = []
      length.times do |pos|
        remaining = length - pos - 1
        @transitions[state].each_with_index do |target, ci|
          next unless target

          amount = @exact[target][remaining]
          if index < amount
            chars << @alphabet[ci]
            state = target
            break
          end
          index -= amount
        end
      end
      chars.join
    end

    # A uniformly random distinct string, drawn with an explicitly provided
    # random source - anything responding to #rand(Integer), e.g. Random.new.
    # Each distinct string has the same probability, no matter how many parse
    # paths match it.
    def sample(random:)
      total = count
      raise Regexp::Parser::Error, 'cannot sample: no strings matched within the length bounds' if total.zero?

      unrank(random.rand(total))
    end

    private

    def normalize_alphabet(alphabet)
      chars = alphabet.is_a?(String) ? alphabet.chars : alphabet.to_a
      raise ArgumentError, 'alphabet must not be empty' if chars.empty?

      chars.each do |char|
        unless char.is_a?(String) && char.length == 1
          raise ArgumentError, "alphabet entries must be single-character strings, got #{char.inspect}"
        end
      end
      raise ArgumentError, 'alphabet must not contain duplicate characters' if chars.uniq.length != chars.length

      chars.freeze
    end

    def validate_length(name, value)
      Integer(value)
    rescue TypeError, ArgumentError
      raise ArgumentError, "#{name} must be an Integer, got #{value.inspect}"
    end

    # exact[state][len] = number of distinct strings of exactly +len+
    # characters accepted when starting in +state+.
    def build_count_table
      exact = @accepting.map { |accepting| [accepting ? 1 : 0] }
      1.upto(@max_length) do |len|
        @transitions.each_with_index do |row, state|
          total = 0
          row.each { |target| total += exact[target][len - 1] if target }
          exact[state] << total
        end
      end
      exact
    end

    # Builds an NFA from the expression tree and determinizes it via subset
    # construction, so that every distinct string has exactly one accepting
    # path. This is what deduplicates overlapping alternatives.
    class Automaton
      attr_reader :start, :transitions, :accepting

      def initialize(root, alphabet)
        @alphabet   = alphabet
        @eps        = []
        @char_trans = []
        nfa_start   = new_state
        nfa_accept  = new_state
        add_expression(root, nfa_start, nfa_accept)
        determinize(nfa_start, nfa_accept)
      end

      private

      E = Regexp::Expression

      def new_state
        @eps << []
        @char_trans << []
        @eps.length - 1
      end

      def add_expression(exp, from, to)
        if exp.quantified?
          add_repetition(exp, exp.quantifier.min, exp.quantifier.max, from, to)
        else
          add_single(exp, from, to)
        end
      end

      def add_repetition(exp, min, max, from, to)
        current = from
        min.times do
          nxt = new_state
          add_single(exp, current, nxt)
          current = nxt
        end
        if max < 0 # unbounded: loop through the expression
          add_epsilon(current, to)
          add_single(exp, current, current)
        else
          (max - min).times do
            add_epsilon(current, to)
            nxt = new_state
            add_single(exp, current, nxt)
            current = nxt
          end
          add_epsilon(current, to)
        end
      end

      def add_single(exp, from, to)
        case exp
        when E::Backreference::Base
          unsupported(exp, 'backreferences, subexpression calls, and recursion are not supported')
        when E::Assertion::Base
          unsupported(exp, 'lookaround assertions are not supported')
        when E::Conditional::Expression, E::Conditional::Condition
          unsupported(exp, 'conditional expressions are not supported')
        when E::Group::Atomic
          unsupported(exp, 'atomic groups are not supported')
        when E::Group::Absence
          unsupported(exp, 'absence operators are not supported')
        when E::Keep::Mark
          unsupported(exp, '\K is not supported')
        when E::Anchor::WordBoundary, E::Anchor::NonWordBoundary,
             E::Anchor::MatchStart, E::Anchor::EndOfStringOrBeforeEndOfLine
          unsupported(exp, "context-dependent anchor #{exp.text} is not supported")
        when E::CharacterType::Linebreak, E::CharacterType::ExtendedGrapheme,
             E::EscapeSequence::CodepointList
          unsupported(exp, "variable-length expression #{exp.text} is not supported")
        when E::Root, E::Sequence,
             E::Group::Capture, E::Group::Passive, E::Group::Options
          add_sequence(exp.expressions, from, to)
        when E::Alternation
          exp.alternatives.each { |alt| add_expression(alt, from, to) }
        when E::Literal
          add_literal(exp, from, to)
        when E::CharacterSet, E::CharacterType::Base,
             E::EscapeSequence::Base, E::UnicodeProperty::Base
          add_terminal(exp, from, to)
        when E::Anchor::BeginningOfLine, E::Anchor::EndOfLine,
             E::Anchor::BeginningOfString, E::Anchor::EndOfString,
             E::FreeSpace, E::Group::Comment
          add_epsilon(from, to)
        else
          unsupported(exp, "#{exp.class} is not supported")
        end
      end

      def unsupported(exp, message)
        raise UnsupportedExpressionError, "#{message} (#{exp.class} #{exp.text.inspect})"
      end

      def add_sequence(expressions, from, to)
        current = from
        expressions.each_with_index do |subexp, index|
          nxt = index == expressions.length - 1 ? to : new_state
          add_expression(subexp, current, nxt)
          current = nxt
        end
        add_epsilon(from, to) if expressions.empty?
      end

      def add_literal(exp, from, to)
        add_sequence_chars(exp.text.chars, exp, from, to)
      end

      def add_sequence_chars(chars, exp, from, to)
        current = from
        chars.each_with_index do |char, index|
          nxt = index == chars.length - 1 ? to : new_state
          add_char_transition(current, matching_indices(char_regexp(Regexp.escape(char), exp)), nxt)
          current = nxt
        end
        add_epsilon(from, to) if chars.empty?
      end

      def add_terminal(exp, from, to)
        add_char_transition(from, matching_indices(char_regexp(exp.to_s(:base), exp)), to)
      end

      def add_char_transition(from, indices, to)
        @char_trans[from] << [indices, to] unless indices.empty?
      end

      def add_epsilon(from, to)
        @eps[from] << to
      end

      def char_regexp(source, exp)
        flags = 0
        flags |= ::Regexp::IGNORECASE if exp.i?
        flags |= ::Regexp::MULTILINE if exp.m?
        ::Regexp.new("\\A(?:#{source})\\z", flags)
      end

      def matching_indices(regexp)
        @alphabet.each_index.select { |i| regexp === @alphabet[i] }
      end

      def determinize(nfa_start, nfa_accept)
        alphabet_size = @alphabet.length
        by_char = @char_trans.map do |transitions|
          grouped = Array.new(alphabet_size) { [] }
          transitions.each do |indices, target|
            indices.each { |ci| grouped[ci] << target }
          end
          grouped
        end

        start_set = epsilon_closure([nfa_start])
        state_ids = { start_set => 0 }
        queue = [start_set]
        @start = 0
        @transitions = []
        @accepting = []
        until queue.empty?
          set = queue.shift
          id = state_ids[set]
          @accepting[id] = set.include?(nfa_accept)
          row = Array.new(alphabet_size)
          alphabet_size.times do |ci|
            targets = []
            set.each { |nfa_state| targets.concat(by_char[nfa_state][ci]) }
            next if targets.empty?

            target_set = epsilon_closure(targets)
            target_id = state_ids[target_set]
            unless target_id
              target_id = state_ids.length
              state_ids[target_set] = target_id
              queue << target_set
            end
            row[ci] = target_id
          end
          @transitions[id] = row
        end
      end

      def epsilon_closure(states)
        closure = []
        visited = {}
        stack = states
        until stack.empty?
          state = stack.pop
          next if visited[state]

          visited[state] = true
          closure << state
          stack.concat(@eps[state])
        end
        closure.sort!
      end
    end
    private_constant :Automaton
  end
end
