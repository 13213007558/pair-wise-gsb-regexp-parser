# frozen_string_literal: true

class Regexp::Parser
  module Language
    class Comparator
      DEFAULT_STATE_LIMIT = 128

      def self.equivalent(left, right, alphabet, max_states: DEFAULT_STATE_LIMIT)
        compare(left, right, alphabet, :equivalent, max_states)
      end

      def self.subset(left, right, alphabet, max_states: DEFAULT_STATE_LIMIT)
        compare(left, right, alphabet, :subset, max_states)
      end

      def self.compare(left, right, alphabet, mode, max_states)
        alphabet = normalize_alphabet(alphabet)
        left_pattern = left
        right_pattern = right
        left_dfa = build(left, alphabet, max_states)
        right_dfa = build(right, alphabet, max_states)

        return left_dfa if left_dfa.is_a?(Result)
        return right_dfa if right_dfa.is_a?(Result)

        if mode == :equivalent
          prove_equivalent(left_dfa, right_dfa, alphabet, left_pattern, right_pattern)
        else
          prove_included(left_dfa, right_dfa, alphabet, left_pattern, right_pattern)
        end
      end

      def self.build(pattern, alphabet, max_states)
        compiled = Compiler.compile(pattern, alphabet, max_states)
        return Result.unknown(compiled[:error].message) if compiled.key?(:error)
        DFA.build(
          nfa: compiled[:nfa],
          start: compiled[:start],
          accept: compiled[:accept],
          prefix_loop: compiled[:prefix_loop],
          pattern_accept: compiled[:pattern_accept],
          alphabet: alphabet,
          state_limit: max_states
        )
      rescue DFA::StateLimit, NFA::StateLimit => error
        Result.unknown(error.message)
      end
      private_class_method :build, :compare

      def self.prove_included(left, right, alphabet, left_pattern, right_pattern)
        witness = product_witness(left, right, alphabet) do |left_state, right_state|
          accepting?(left, left_state) && !accepting?(right, right_state)
        end
        return Result.included(:subset) if witness.nil?
        verified_result(witness, left_pattern, right_pattern, true, false)
      end
      private_class_method :prove_included

      def self.prove_equivalent(left, right, alphabet, left_pattern, right_pattern)
        witness = product_witness(left, right, alphabet) do |left_state, right_state|
          accepting?(left, left_state) != accepting?(right, right_state)
        end
        return Result.equivalent if witness.nil?

        left_accepts = accepting?(left, witness[:left])
        right_accepts = accepting?(right, witness[:right])
        if left_accepts && !right_accepts
          verified_result(witness, left_pattern, right_pattern, true, false)
        elsif !left_accepts && right_accepts
          verified_result(witness, left_pattern, right_pattern, false, true)
        else
          Result.unknown("counterexample verification failed for #{witness[:string].inspect}")
        end
      end
      private_class_method :prove_equivalent

      def self.verified_result(witness, left_pattern, right_pattern,
                              expected_left, expected_right)
        string = witness[:string]
        left_accepts = ruby_match?(left_pattern, string)
        right_accepts = ruby_match?(right_pattern, string)
        unless left_accepts == expected_left && right_accepts == expected_right
          return Result.unknown("counterexample verification failed for #{string.inspect}")
        end

        direction = expected_left ? :left_accepted_right_rejected :
                               :right_accepted_left_rejected
        Result.not_included(string, direction, left_accepts, right_accepts)
      end
      private_class_method :verified_result

      def self.ruby_match?(pattern, string)
        regexp = pattern.is_a?(::Regexp) ? pattern : Regexp.new(pattern)
        !regexp.match(string).nil?
      end
      private_class_method :ruby_match?

      def self.product_witness(left, right, alphabet)
        start = [left[:initial], right[:initial]]
        seen = Set.new([start])
        pending = [{ pair: start, string: '', parent: nil }]

        until pending.empty?
          node = pending.shift
          left_state, right_state = node[:pair]

          if yield(left_state, right_state)
            return { string: node[:string], left: left_state, right: right_state }
          end

          alphabet.each do |character|
            string = node[:string] + character
            if character == DFA::NEWLINE
              enqueue_transition(pending, seen, left, right,
                                 left_state, right_state, string, :terminal_newline)
              enqueue_transition(pending, seen, left, right,
                                 left_state, right_state, string, [:char, DFA::NEWLINE])
            else
              enqueue_transition(pending, seen, left, right,
                                 left_state, right_state, string, [:char, character])
            end
          end
        end

        nil
      end
      private_class_method :product_witness

      def self.enqueue_transition(pending, seen, left, right,
                                  left_state, right_state, string, symbol)
        left_transition = transition(left, left_state, symbol)
        right_transition = transition(right, right_state, symbol)
        return if left_transition.nil? || right_transition.nil?
        pair = [left_transition, right_transition]
        return if seen.include?(pair)
        seen << pair
        pending << { pair: pair, string: string, parent: nil }
      end
      private_class_method :enqueue_transition

      def self.transition(dfa, state, symbol)
        key = keys_for(dfa, state)
        next_key = dfa[:states].fetch(key)[:transitions][symbol]
        next_key ? state_id_for_key(dfa, next_key) : dead_state(dfa)
      end
      private_class_method :transition

      def self.keys_for(dfa, state_id)
        build_key_ids(dfa)
        dfa[:key_ids].fetch(state_id)
      rescue NoMethodError, KeyError
        build_key_ids(dfa)
        dfa[:key_ids].fetch(state_id)
      end
      private_class_method :keys_for

      def self.build_key_ids(dfa)
        dfa[:key_ids] = {}
        dfa[:states].each { |key, state| dfa[:key_ids][state[:id]] = key }
      end
      private_class_method :build_key_ids

      def self.accepting?(dfa, state)
        dfa[:states].fetch(keys_for(dfa, state))[:accepting]
      end
      private_class_method :accepting?

      def self.state_id_for_key(dfa, key)
        dfa[:states].fetch(key)[:id]
      end
      private_class_method :state_id_for_key

      def self.dead_state(dfa)
        dfa[:dead]
      end
      private_class_method :dead_state

      def self.normalize_alphabet(alphabet)
        characters =
          case alphabet
          when String then alphabet.each_char.to_a
          when Array then alphabet
          else raise ArgumentError, 'alphabet must be a String or an Array of characters'
          end

        characters.each do |character|
          unless character.is_a?(String) && character.length == 1
            raise ArgumentError, 'alphabet entries must be one-character Strings'
          end
        end

        characters.uniq
      end
      private_class_method :normalize_alphabet
    end
  end
end
