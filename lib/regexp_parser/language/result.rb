# frozen_string_literal: true

class Regexp::Parser
  module Language
    class Result
      STATUSES = [:equivalent, :included, :not_included, :unknown].freeze

      attr_reader :status, :relation, :counterexample, :direction,
                  :left_accepts, :right_accepts, :reason

      def self.included(relation = :subset)
        new(:included, relation)
      end

      def self.equivalent
        new(:equivalent, :equivalent)
      end

      def self.not_included(string, direction, left_accepts, right_accepts)
        new(:not_included, :none,
            counterexample: string,
            direction: direction,
            left_accepts: left_accepts,
            right_accepts: right_accepts)
      end

      def self.unknown(reason)
        new(:unknown, :unknown, reason: reason)
      end

      def equivalent?
        status == :equivalent
      end

      def included?
        status == :included
      end

      def not_included?
        status == :not_included
      end

      def unknown?
        status == :unknown
      end

      def proven?
        !unknown?
      end

      def to_h
        {
          status: status,
          relation: relation,
          counterexample: counterexample,
          direction: direction,
          left_accepts: left_accepts,
          right_accepts: right_accepts,
          reason: reason
        }
      end

      private_class_method :new

      private

      def initialize(status, relation, counterexample: nil, direction: nil,
                     left_accepts: nil, right_accepts: nil, reason: nil)
        @status = status
        @relation = relation
        @counterexample = counterexample
        @direction = direction
        @left_accepts = left_accepts
        @right_accepts = right_accepts
        @reason = reason
      end
    end
  end
end
