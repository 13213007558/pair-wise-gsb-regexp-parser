# frozen_string_literal: true

class Regexp::Parser
  module Language
    # Outcome of an inclusion or equivalence check.
    #
    # Status is one of:
    # * +:included+ / +:equivalent+ - the property was proved
    # * +:not_included+ / +:not_equivalent+ - disproved; #counterexample is
    #   a string accepted by one side and rejected by the other
    # * +:unknown+ - no claim can be made (unsupported feature or exceeded
    #   the state budget); #reason explains why
    class Result
      STATUSES = %i[
      included equivalent not_included not_equivalent unknown
      ].freeze

      attr_reader :status, :counterexample, :direction,
      :accepted_by, :rejected_by, :reason, :detail, :method

      def initialize(status, counterexample: nil, direction: nil,
        accepted_by: nil, rejected_by: nil,
        reason: nil, detail: nil, used_method: nil)
        raise ArgumentError, status unless STATUSES.include?(status)

        @status         = status
        @counterexample = counterexample
        @direction      = direction
        @accepted_by    = accepted_by
        @rejected_by    = rejected_by
        @reason         = reason
        @detail         = detail
        @method         = used_method
      end

      def self.included(direction:, method:)
        new(:included, direction: direction, used_method: method)
      end

      def self.equivalent(method:)
        new(:equivalent, used_method: method)
      end

      def self.not_included(counterexample:, direction:,
        accepted_by:, rejected_by:, method:)
        new(:not_included, counterexample: counterexample, direction: direction,
        accepted_by: accepted_by, rejected_by: rejected_by, used_method: method)
      end

      def self.unknown(reason, detail = nil)
        new(:unknown, reason: reason, detail: detail)
      end

      def included?
        @status == :included
      end

      def equivalent?
        @status == :equivalent
      end

      def not_included?
        @status == :not_included
      end

      alias_method :not_equivalent?, :not_included?

      # True only when a definitive proof or disproof was produced.
      def proven?
        !unknown?
      end

      def unknown?
        @status == :unknown
      end

      def to_h
        {
          status: status, counterexample: counterexample, direction: direction,
          accepted_by: accepted_by, rejected_by: rejected_by,
          reason: reason, detail: detail, method: method
        }
      end
    end
  end
end
