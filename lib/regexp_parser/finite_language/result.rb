# frozen_string_literal: true

class Regexp::Parser
  class FiniteLanguage
    # Returned by {FiniteLanguage#count}, {FiniteLanguage#nth} and
    # {FiniteLanguage#sample}. Check {#complete?} (or its negation {#incomplete?})
    # before using {#value}: an incomplete result means the given +budget+ was
    # exhausted and the answer is unknown. Incomplete results are never turned
    # into approximate answers.
    class Result
      attr_reader :value, :reason

      def initialize(value, complete:, reason: nil)
        @value = value
        @complete = complete
        @reason = reason
      end

      def complete?
        @complete
      end

      def incomplete?
        !@complete
      end

      # Returns the value or raises +error_class+ if the result is incomplete.
      def value!(error_class = BudgetExhausted)
        raise error_class, @reason if incomplete?

        @value
      end

      def ==(other)
        other.is_a?(Result) &&
          complete? == other.complete? &&
          value == other.value
      end
      alias eql? ==

      def hash
        [@complete, @value].hash
      end

      def inspect
        if complete?
          "#<#{self.class.name} #{@value.inspect}>"
        else
          "#<#{self.class.name} incomplete#{@reason ? " (#{@reason})" : ''}>"
        end
      end
      alias to_s inspect
    end
  end
end
