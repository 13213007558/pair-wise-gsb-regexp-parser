# frozen_string_literal: true

class Regexp::Parser::Language
  # Simple operation counter shared by compilation and DP work.
  class Budget
    DEFAULT_LIMIT = 1_000_000

    attr_reader :limit, :used

    def initialize(limit = DEFAULT_LIMIT)
      limit = self.class.normalize(limit)
      @limit = limit
      @used = 0
    end

    def self.normalize(limit)
      unless limit.is_a?(Integer) && limit >= 0
        raise Regexp::Parser::LanguageArgumentError,
              "budget must be a non-negative Integer, got #{limit.inspect}"
      end

      limit
    end

    def charge!(amount = 1)
      @used += amount
    end

    def alive?
      @used <= @limit
    end

    def exhausted?
      !alive?
    end
  end
end
