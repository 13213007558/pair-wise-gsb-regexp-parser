# frozen_string_literal: true

class Regexp
  module BacktrackingAnalysis
    Location = Struct.new(:expression, :starts_at, :length, :label)
    Witness = Struct.new(:prefix, :repeatable, :suffix)
    Trend = Struct.new(:sizes, :step_counts, :growth)
    Finding = Struct.new(:severity, :reason, :locations, :witness, :trend)
    Result = Struct.new(:status, :findings, :unsupported) do
      def safe?
        status.equal?(:safe)
      end

      def unknown?
        status.equal?(:unknown)
      end

      def vulnerable?
        status.equal?(:vulnerable)
      end
    end

    class UnsupportedFeature < StandardError
      attr_reader :expression

      def initialize(message, expression = nil)
        @expression = expression
        super(message)
      end
    end

    def self.analyze(pattern, max_witness_length = nil, trend_sizes = nil)
      root = pattern.is_a?(Regexp::Expression::Base) ? pattern : Parser.parse(pattern)
      analyzer = Analyzer.new(
        root,
        max_witness_length || 5,
        trend_sizes || [6, 8, 10, 12]
      )
      analyzer.analyze
    rescue Regexp::Parser::Error => error
      unsupported_result(error.message, nil)
    end

    def self.unsupported_result(message, expression)
      location = expression ? location(expression, 'unsupported AST node') : nil
      Result.new(
        :unknown,
        [],
        Finding.new(:unknown, message, [location].compact, nil, nil)
      )
    end

    def self.location(exp, label = nil)
      Location.new(exp, exp.starts_at, exp.full_length, label)
    end
  end
end

require_relative 'backtracking_analysis/characters'
require_relative 'backtracking_analysis/support'
require_relative 'backtracking_analysis/path_counter'
require_relative 'backtracking_analysis/interpreter'
require_relative 'backtracking_analysis/analyzer'
