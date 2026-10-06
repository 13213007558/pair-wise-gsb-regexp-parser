# frozen_string_literal: true

require_relative 'parser'
require_relative 'finite_language/result'
require_relative 'finite_language/nfa'
require_relative 'finite_language/compiler'
require_relative 'finite_language/engine'

class Regexp::Parser
  # Treats a regular expression as the set of strings it matches and answers
  # questions about that set at a fixed string length.
  #
  # Strings are counted as elements of a set: syntax paths that generate the
  # same string (e.g. +a|a+) contribute it only once. Counting is done over a
  # finite character domain (+alphabet+), with which every character class is
  # intersected. Counts use Ruby Integer (arbitrary precision).
  #
  # Patterns must be free of backreferences, recursive subexpression calls,
  # lookarounds, conditionals, absence groups, keep marks (+\K+), word
  # boundaries (+\b+/+\B+), +\R+ and +\X+. Quantifiers may be unbounded
  # (+*+, +{n,}+, ...): each query fixes one length, so every answer remains
  # finite.
  #
  # == Semantics
  # * Empty string: patterns that can match +""+ are supported; use
  #   <tt>count(0)</tt>. Greedy, reluctant and possessive quantifiers have the
  #   same language.
  # * Anchors: +\A+, +\G+ and +^+ mean start-of-string; +\z+ means
  #   end-of-string; +\Z+ and +$+ mean end-of-string or immediately before a
  #   trailing newline (Ruby's non-multiline semantics). Multiline +^+/+$+ and
  #   word boundaries are rejected. Quantified anchors are honored at their
  #   boundary.
  #
  # == Budgets
  # Every query takes a +budget+ of internal work steps. Exhausting it returns
  # an incomplete {Result} rather than an approximate or biased value.
  #
  # == Examples
  #   lang = Regexp::Parser::FiniteLanguage.new('a|a', %w[a b])
  #   lang.count(1).value   # => 1
  #   lang.nth(1, 0).value  # => "a"
  #   lang.sample(1, seed: 7).value
  class FiniteLanguage
    class Error < Regexp::Parser::Error; end

    # Pattern uses a feature outside the supported regular-language fragment.
    class UnsupportedFeature < Error; end

    # A query exceeded its budget; used by {Result#value!}.
    class BudgetExhausted < Error; end

    # A bad argument (negative length/rank, wrong types, empty sampling set).
    class InvalidQuery < Error; end

    DEFAULT_BUDGET = 50_000

    # @param pattern [Regexp, String] pattern to analyze
    # @param alphabet [Array<String>, Range<String>, String, nil] finite
    #   character domain. A String is split into characters; a character Range
    #   is expanded. Defaults to printable ASCII (<tt>(0x20..0x7e)</tt>).
    def initialize(pattern, alphabet = nil)
      @root = parse(pattern)
      @alphabet = normalize_alphabet(alphabet)
      @matcher_cache = {}
      validate!(@root)
    end

    attr_reader :alphabet

    # Number of distinct strings of exactly +length+ characters.
    # @return [Result<Integer>]
    def count(length, budget: DEFAULT_BUDGET)
      run(budget) { |engine| engine.count(normalize_length(length)) }
    end

    # The string at zero-based +rank+ (alphabet/codepoint order) among distinct
    # strings of exactly +length+ characters. Iterating ranks 0...count yields
    # each distinct string once regardless of syntactic overlap.
    # @return [Result<String>]
    def nth(length, rank, budget: DEFAULT_BUDGET)
      n = normalize_length(length)
      raise InvalidQuery, 'rank must be an Integer' unless rank.is_a?(Integer)
      raise InvalidQuery, 'rank cannot be negative' if rank.negative?

      run(budget) { |engine| engine.nth(n, rank) }
    end

    # Uniformly samples one distinct string of exactly +length+ characters.
    # Uniformity is over distinct strings, so overlapping branches never
    # bias the result.
    # @param seed [Integer, Random, nil] Integer seeds are reproducible.
    # @return [Result<String>]
    def sample(length, seed: nil, budget: DEFAULT_BUDGET)
      n = normalize_length(length)
      random =
        case seed
        when nil then Random.new
        when Random then seed
        when Integer then Random.new(seed)
        else raise InvalidQuery, 'seed must be an Integer or a Random'
        end
      run(budget) { |engine| engine.sample(n, random) }
    end

    # Enumerates all distinct strings of exactly +length+ characters in
    # alphabet order. Returns an Enumerator without a block. Enumeration is
    # exact (same strings as count and nth) and aborts with BudgetExhausted
    # if the budget cannot cover it.
    def each(length, budget: DEFAULT_BUDGET, &block)
      return to_enum(:each, length, budget: budget) unless block

      n = normalize_length(length)
      total = count(n, budget: budget)
      raise BudgetExhausted, total.reason if total.incomplete?

      total.value.times do |rank|
        result = nth(n, rank, budget: budget)
        raise BudgetExhausted, result.reason if result.incomplete?

        block.call(result.value)
      end
      self
    end

    # @api private
    def build_nfa(budget: DEFAULT_BUDGET)
      Compiler.new(self, budget).compile(@root)
    end

    # @api private
    def matcher_for(atom)
      @matcher_cache[atom.cache_key] ||= atom.build_matcher
    end

    private

    def run(budget)
      raise InvalidQuery, 'budget must be an Integer' unless budget.is_a?(Integer)
      raise InvalidQuery, 'budget must be positive' if budget <= 0

      value = yield(Engine.new(self, budget))
      Result.new(value, complete: true)
    rescue BudgetExhausted => e
      Result.new(nil, complete: false, reason: e.message)
    end

    def parse(pattern)
      case pattern
      when ::Regexp then Regexp::Parser.parse(pattern)
      when String
        syntax = "ruby/#{RUBY_VERSION.split('.').first(2).join('.')}"
        Regexp::Parser.parse(pattern, syntax)
      else raise InvalidQuery, 'pattern must be a Regexp or a String'
      end
    end

    def normalize_alphabet(alphabet)
      chars =
        case alphabet
        when nil then (0x20..0x7e).map { |cp| cp.chr(Encoding::UTF_8) }
        when String then alphabet.chars
        when Range then alphabet.to_a
        when Array then alphabet.dup
        else raise InvalidQuery, 'alphabet must be an Array, Range or String'
        end
      unless chars.all? { |c| c.is_a?(String) && c.length == 1 }
        raise InvalidQuery, 'alphabet entries must be single-character Strings'
      end

      chars.uniq.sort_by(&:ord).freeze
    end

    def normalize_length(length)
      unless length.is_a?(Integer)
        raise InvalidQuery, 'length must be an Integer'
      end
      raise InvalidQuery, 'length cannot be negative' if length.negative?

      length
    end

    def validate!(node)
      if node.respond_to?(:quantifier) && node.quantifier &&
         node.quantifier.possessive?
        raise UnsupportedFeature,
              "possessive quantifiers are not a regular language: #{node.text}"
      end
      case node
      when Regexp::Expression::Backreference::Base,
           Regexp::Expression::Conditional::Expression,
           Regexp::Expression::Assertion::Base,
           Regexp::Expression::Keep::Mark,
           Regexp::Expression::Group::Absence,
           Regexp::Expression::Anchor::WordBoundary,
           Regexp::Expression::Anchor::NonWordBoundary,
           Regexp::Expression::CharacterType::Linebreak,
           Regexp::Expression::CharacterType::ExtendedGrapheme
        name = node.class.name.sub(/.*Expression::/, '')
        raise UnsupportedFeature, "unsupported expression: #{name}"
      when Regexp::Expression::Anchor::BeginningOfLine,
           Regexp::Expression::Anchor::EndOfLine
        if node.options[:m]
          raise UnsupportedFeature,
                'multiline ^ and $ anchors are not supported'
        end
      end

      return unless node.respond_to?(:expressions)

      node.expressions.each { |child| validate!(child) }
    end
  end
end
