# frozen_string_literal: true

class Regexp::Parser
  module Language
    # Raised while compiling a pattern when it uses a construct outside of the
    # supported regular-expression subset. The driver converts this into an
    # +unknown+ result rather than guessing.
    class UnknownFeature < ::Regexp::Parser::Error
      attr_reader :reason, :detail

      def initialize(reason, detail = nil)
        @reason = reason
        @detail = detail
        super(detail ? "#{reason}: #{detail}" : reason.to_s)
      end
    end
  end
end
