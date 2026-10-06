# frozen_string_literal: true

require_relative 'parser'
require_relative 'language/error'
require_relative 'language/budget'
require_relative 'language/random'
require_relative 'language/result'
require_relative 'language/compiler'

class Regexp::Parser
  # Finite-language interface for a restricted class of regular expressions.
  #
  # A Language describes the *set of distinct strings* matched by a regexp
  # (semantic language, not syntactic paths): /a|a/ is the same language as
  # /a/. It supports:
  #
  #   * counting the strings of an exact length (big integers),
  #   * retrieving the nth string in lexicographic order (unranking),
  #   * reproducible uniform sampling with an integer or string seed,
  #   * complete small-range enumeration.
  #
  # Restrictions:
  #
  #   * the character domain must be finite. Closed classes such as \d or
  #     [a-z] infer their domain automatically; open classes such as +.+,
  #     [^x] or \p{Alpha} require an explicit +alphabet:,
  #   * no backreferences, no recursion/subexpression calls,
  #   * no lookarounds, conditionals, absence groups or \K,
  #   * supported anchors are \A, ^, \z, \Z, $, \G, \b and \B. ^/$/\Z use
  #     whole-string semantics (they do not match at embedded newlines).
  #   * empty alternatives and empty repetitions are supported: the empty
  #     string is a genuine word of length 0.
  #
  # All operations take an operation +budget+. When the budget is exhausted
  # before an exact result is known, an incomplete Result is returned
  # instead of a biased approximation.
  class Language
    # Builds a language from a Regexp, a parse tree or a regexp source
    # string.
    def initialize(pattern, alphabet: nil, budget: Budget::DEFAULT_LIMIT)
      regexp, tree, global_options = coerce_pattern(pattern)
      @regexp = regexp
      @global_options = global_options
      @tree = tree
      @alphabet_arg = alphabet
      @default_budget = budget
      bootstrap = Compiler.prepare(tree, global_options, alphabet,
                                   Budget.new(@default_budget))
      @resolved_alphabet = bootstrap.alphabet
    end

    attr_reader :regexp

    # Effective finite alphabet for the language. Inferring it may raise
    # InfiniteAlphabetError for open character classes.
    def alphabet
      @resolved_alphabet ||= build_compiler(0, Budget.new(@default_budget)).alphabet
    end

    # Counts the distinct strings matched at exactly +length+ characters.
    # Returns a Result wrapping a big Integer.
    def count(length, budget: @default_budget)
      positive_length!(length)
      counter = Budget.new(budget)
      compiler = build_compiler(length, counter)
      counts, complete = compiler.counts(length)
      Result.new(complete ? counts[length] : nil, complete, counter)
    end

    # Returns the string at a zero-based lexicographic rank among the
    # strings of exactly +length+ characters. Rank order is by codepoint.
    def nth(length, rank, budget: @default_budget)
      positive_length!(length)
      unless rank.is_a?(Integer) && rank >= 0
        raise LanguageArgumentError, "rank must be a non-negative Integer, got #{rank.inspect}"
      end

      counter = Budget.new(budget)
      compiler = build_compiler(length, counter)
      total, complete = compiler.counts(length)
      unless complete
        return Result.new(nil, false, counter)
      end
      if rank >= total[length]
        raise LanguageArgumentError,
              "rank #{rank} is out of range (0...#{total[length]}) for length #{length}"
      end

      string = compiler.nth(length, rank)
      complete = !string.nil? && counter.alive?
      Result.new(string, complete, counter)
    end

    # Draws one string uniformly among the distinct strings of exactly
    # +length+ characters. Equal strings have exactly one chance, even
    # when the regexp provides several syntactic paths to them.
    def sample(length, seed: 0, budget: @default_budget)
      positive_length!(length)
      counter = Budget.new(budget)
      random = Random.new(seed)
      compiler = build_compiler(length, counter)
      counts, complete = compiler.counts(length)
      unless complete
        return Result.new(nil, false, counter)
      end

      total = counts[length]
      return Result.new(nil, counter.alive?, counter) if total.zero?

      rank = random.integer(total)
      string = compiler.nth(length, rank)
      complete = !string.nil? && counter.alive?
      Result.new(string, complete, counter)
    end

    # Draws +count+ strings with one seeded RNG stream and returns a
    # Result wrapping an Array. This is the reproducible way to draw more
    # than one sample at a time.
    def samples(length, count, seed: 0, budget: @default_budget)
      positive_length!(length)
      unless count.is_a?(Integer) && count >= 0
        raise LanguageArgumentError,
              "count must be a non-negative Integer, got #{count.inspect}"
      end

      counter = Budget.new(budget)
      random = Random.new(seed)
      compiler = build_compiler(length, counter)
      counts, complete = compiler.counts(length)
      return Result.new([], false, counter) unless complete

      total = counts[length]
      return Result.new([], counter.alive?, counter) if total.zero?

      strings = Array.new(count) do
        rank = random.integer(total)
        string = compiler.nth(length, rank)
        return Result.new(strings, false, counter) if string.nil?

        string
      end
      Result.new(strings, counter.alive?, counter)
    end

    # Enumerates every distinct string of exactly +length+ characters in
    # lexicographic order. Returns a Result wrapping an Array.
    def enumerate(length, budget: @default_budget)
      positive_length!(length)
      counter = Budget.new(budget)
      compiler = build_compiler(length, counter)
      counts, complete = compiler.counts(length)
      unless complete
        return Result.new([], false, counter)
      end

      total = counts[length]
      strings = []
      total.times do |rank|
        string = compiler.nth(length, rank)
        return Result.new(strings, false, counter) if string.nil?
        strings << string
      end
      Result.new(strings, counter.alive?, counter)
    end

    private

    def positive_length!(length)
      unless length.is_a?(Integer) && length >= 0
        raise LanguageArgumentError,
              "length must be a non-negative Integer, got #{length.inspect}"
      end
    end

    def build_compiler(length, budget)
      Compiler.new(@tree, @global_options, @alphabet_arg, budget).build(length)
    end

    def coerce_pattern(pattern)
      case pattern
      when ::Regexp
        tree = Regexp::Parser.parse(pattern)
        [pattern, tree, pattern.options]
      when Regexp::Expression::Root
        source = pattern.to_s
        regexp = ::Regexp.new(source)
        [regexp, pattern, regexp.options]
      when String
        regexp = ::Regexp.new(pattern)
        [regexp, Regexp::Parser.parse(regexp), regexp.options]
      else
        raise LanguageArgumentError,
              "expected a Regexp, a parse tree or a String, got #{pattern.class}"
      end
    end
  end
end
