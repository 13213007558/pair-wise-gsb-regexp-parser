# frozen_string_literal: true

require_relative 'nfa_simulator'

class Regexp::Parser
  module Language
    # Exhaustive enumeration over the alphabet, using the exact same gated
    # NFA simulation as the product analysis.
    #
    # When both languages are finite this enumerates every string up to the
    # maximum accepted length and decides inclusion exactly. Otherwise it
    # covers strings up to a budget as an independent cross-check.
    class Enumerator
      def self.check_inclusion(subset, superset, alphabet, product_witness, budget)
        new(subset, superset, alphabet, budget, product_witness).check
      end

      def initialize(subset, superset, alphabet, budget, product_witness)
        @subset = subset
        @superset = superset
        @alphabet = alphabet
        @budget = budget
        @product_witness = product_witness
      end

      def check
        max_length =
        if @subset.finite && @superset.finite
          base = [@subset.max_length, @superset.max_length].compact.max
          if @subset.trailing_tolerant || @superset.trailing_tolerant
            base + 1
          else
            base
          end
        else
          cross_check_length
        end
        return nil if max_length.nil?

        Simulator.run(@subset, @superset, @alphabet, max_length, @budget)
      end

      private

      def cross_check_length
        if @product_witness
          @product_witness.length
        else
          depth = 0
          size = 1
          while size <= @budget && depth < 4
            depth += 1
            size *= @alphabet.length
          end
          depth
        end
      end

      # Length-first, codepoint-order enumeration of alphabet strings.
      class Simulator
        def self.run(subset, superset, alphabet, max_length, budget)
          new(subset, superset, alphabet, max_length, budget).run
        end

        def initialize(subset, superset, alphabet, max_length, budget)
          @subset = NfaSimulator.new(subset)
          @superset = NfaSimulator.new(superset)
          @alphabet = alphabet
          @max_length = max_length
          @budget = budget
        end

        def run
          initial = [@subset.start, @superset.start, false]
          queue = [[initial, '']]
          inspected = 0

          until queue.empty?
            state, word = queue.shift
            inspected += 1
            return nil if inspected > @budget

            if mismatch?(state)
              return word
            end
            if word.end_with?(NfaSimulator::NEWLINE) &&
               final_newline_mismatch?(state)
              return word
            end

           next if word.length >= @max_length
           @alphabet.each do |char|
              next_state = advance(state, char)
              if char == NfaSimulator::NEWLINE &&
                 @subset.accept_with_final_newline?(state[0]) &&
                 !superset_accepts_final_newline?(state, state[1])
                return word + char
              end
              queue << [next_state, word + char]
           end
          end
          nil
        end

        private

        def mismatch?(state)
          left, right, previous_newline = state
          @subset.accept?(left, previous_newline) &&
            !@superset.accept?(right, previous_newline)
        end

        def final_newline_mismatch?(state)
          left, right, _previous_newline = state
          @subset.accept_with_final_newline?(left) &&
            !superset_accepts_final_newline?(state, right)
        end

        def superset_accepts_final_newline?(state, right)
          return true if @superset.accept_with_final_newline?(right)
          advanced = @superset.advance(right, NfaSimulator::NEWLINE, state[2])
          @superset.accept?(advanced, true)
        end

        def advance(state, char)
          [
            @subset.advance(state[0], char, state[2]),
            @superset.advance(state[1], char, state[2]),
            char == NfaSimulator::NEWLINE
          ]
        end
      end
    end
  end
end
