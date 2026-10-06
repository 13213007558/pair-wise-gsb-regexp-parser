# frozen_string_literal: true

class Regexp::Parser::Language
  # Wraps the outcome of a counting, ranking or sampling operation.
  #
  # Every operation is bounded by an explicit work budget. When the budget
  # is exhausted before the exact result is known, the result is returned
  # with #complete? == false instead of silently producing a biased value.
  class Result
    attr_reader :value, :budget

    def initialize(value, complete, budget)
      @value = value
      @complete = complete
      @budget = budget
    end

    def complete?
      @complete
    end

    def incomplete?
      !@complete
    end

    # Returns the exact value, or raises when the computation did not
    # finish within its budget.
    def value!
      raise Regexp::Parser::LanguageError,
            'operation did not finish within the given budget' unless complete?

      @value
    end

    def ==(other)
      other.is_a?(Result) &&
        value == other.value &&
        complete? == other.complete?
    end
    alias eql? ==

    def hash
      [@value, @complete].hash
    end

    def inspect
      "#<#{self.class.name} value=#{value.inspect} complete=#{@complete}>"
    end
  end
end
