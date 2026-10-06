# frozen_string_literal: true

class Regexp::Parser::Language
  # Deterministic 64-bit pseudo random generator (SplitMix64).
  #
  # Using a bundled generator instead of Ruby's Random means that identical
  # seeds produce identical samples on every Ruby version and platform.
  class Random
    MASK = (1 << 64) - 1
    GOLDEN = 0x9e3779b97f4a7c15

    attr_reader :state

    def initialize(seed = 0)
      seed = self.class.coerce_seed(seed)
      @state = seed & MASK
    end

    def self.coerce_seed(seed)
      case seed
      when Integer
        seed
      when String
        # FNV-1a over the UTF-8 bytes of the seed string.
        h = 0xcbf29ce484222325
        seed.each_byte do |byte|
          h = ((h ^ byte) * 0x100000001b3) & MASK
        end
        h
      else
        raise Regexp::Parser::LanguageArgumentError,
              "seed must be an Integer or a String, got #{seed.class}"
      end
    end

    # Returns a uniformly distributed integer in 0...bound.
    # Rejection sampling keeps the distribution unbiased even when the
    # bound does not divide 2**64.
    def integer(bound)
      raise ArgumentError, "bound must be positive" if bound <= 0
      return u64_integer(bound) if bound <= (1 << 64)

      bits = bound.bit_length
      width = bound.bit_length
      limit = (1 << width) - ((1 << width) % bound)
      loop do
        value = wide_integer(bits)
        return value % bound if value < limit
      end
    end

    private

    def u64_integer(bound)
      limit = ((1 << 64) / bound) * bound
      limit = 1 << 64 if bound == 1
      loop do
        value = next_u64
        return value % bound if value < limit
      end
    end

    def wide_integer(bits)
      words = (bits / 64.0).ceil
      value = 0
      words.times do |index|
        value |= next_u64 << (index * 64)
      end
      # Trim to exactly +bits+ bits so the rejection window is minimal.
      value & ((1 << bits) - 1)
    end

    def next_u64
      @state = (@state + GOLDEN) & MASK
      z = @state
      z = ((z ^ (z >> 30)) * 0xbf58476d1ce4e5b9) & MASK
      z = ((z ^ (z >> 27)) * 0x94d049bb133111eb) & MASK
      z ^ (z >> 31)
    end
  end
end
