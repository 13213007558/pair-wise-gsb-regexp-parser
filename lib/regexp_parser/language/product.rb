# frozen_string_literal: true

require_relative 'nfa_simulator'

class Regexp::Parser
  module Language
    # Inclusion check on the product of two NFAs.
    #
    # Each NFA is driven by an NfaSimulator. A breadth-first search over the
    # alphabet in codepoint order returns the shortest, lexicographically
    # smallest counterexample, or nil when inclusion holds.
    class Product
      def initialize(subset, superset, alphabet, max_states)
        @subset = NfaSimulator.new(subset)
        @superset = NfaSimulator.new(superset)
        @alphabet = alphabet
        @max_states = max_states
      end

      def shortest_witness
        initial_state = [@subset.start, @superset.start, false]
        queue = [initial_state]
        parents = { initial_state => nil }
        visited = 0

        until queue.empty?
          state = queue.shift
          visited += 1
          if visited > @max_states
            raise Language::StateLimit,
              'product exploration exceeds ' + @max_states.to_s + ' states'
          end

          word = reconstruct(parents, state)
          return word if mismatch?(state)

          expand(state, queue, parents)
        end
        nil
      end

      private

      def mismatch?(state)
        left, right, previous_newline = state
        return false unless @subset.accept?(left, previous_newline)
        !@superset.accept?(right, previous_newline)
      end

      def expand(state, queue, parents)
        left, right, previous_newline = state
        @alphabet.each do |char|
          if char == NfaSimulator::NEWLINE
            # Ruby can accept one final newline after a top-level $ or \Z.
            witness = final_newline_witness(state, parents)
            return witness if witness
          end
          next_left = @subset.advance(left, char, previous_newline)
          next_right = @superset.advance(right, char, previous_newline)
          next_state = [next_left, next_right, true]
          next if parents.key?(next_state)
          parents[next_state] = [state, char]
          queue << next_state
        end
        nil
      end

      def final_newline_witness(state, parents)
        left, right, _previous_newline = state
        return nil unless @subset.accept_with_final_newline?(left)
        return nil if superset_accepts_final_newline?(state, right)
        word = reconstruct(parents, state) + NfaSimulator::NEWLINE
        enqueue_newline_state(state, parents)
        word
      end

      def superset_accepts_final_newline?(state, right)
        return true if @superset.accept_with_final_newline?(right)
        # Or by consuming the newline and then accepting.
        advanced = @superset.advance(right, NfaSimulator::NEWLINE, state[2])
        @superset.accept?(advanced, true)
      end

      def enqueue_newline_state(state, parents)
        next_left = @subset.advance(state[0], NfaSimulator::NEWLINE, state[2])
        next_right = @superset.advance(state[1], NfaSimulator::NEWLINE, state[2])
        next_state = [next_left, next_right, true]
        return if parents.key?(next_state)
        parents[next_state] = [state, NfaSimulator::NEWLINE]
      end

      def reconstruct(parents, state)
        chars = []
        current = state
        while (entry = parents[current])
          parent, char = entry
          chars << char if char
          current = parent
        end
        chars.reverse.join
      end
    end
  end
end

