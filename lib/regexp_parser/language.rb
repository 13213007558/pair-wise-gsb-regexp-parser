# frozen_string_literal: true

require_relative 'language/result'
require_relative 'language/unknown_feature'
require_relative 'language/oracle'
require_relative 'language/compiler'
require_relative 'language/nfa_simulator'
require_relative 'language/product'
require_relative 'language/enumerator'

class Regexp::Parser
  # Language inclusion and equivalence checking over an explicit, finite
  # character alphabet.
  module Language
    DEFAULT_MAX_STATES         = 2_000
    DEFAULT_MAX_PRODUCT_STATES = 20_000
    DEFAULT_MAX_ENUMERATED     = 200_000

    class StateLimit < Regexp::Parser::Error; end

    def self.analyze_inclusion(left, right, alphabet, **kwargs)
      Analyzer.new(left, right, alphabet, **kwargs).run(:inclusion)
    end

    def self.analyze_equivalence(left, right, alphabet, **kwargs)
      Analyzer.new(left, right, alphabet, **kwargs).run(:equivalence)
    end

    # @!visibility private
    class Analyzer
      def initialize(left, right, alphabet,
                     max_states: Language::DEFAULT_MAX_STATES,
                     max_product_states: Language::DEFAULT_MAX_PRODUCT_STATES,
                     max_enumerated: Language::DEFAULT_MAX_ENUMERATED)
        @alphabet           = Language.normalize_alphabet(alphabet)
        @left_pattern       = left
        @right_pattern      = right
        @max_states         = max_states
        @max_product_states = max_product_states
        @max_enumerated     = max_enumerated
        @nfa_cache          = {}
        @anchored_cache     = {}
        @tolerant_cache     = {}
      end

      def run(kind)
        @left_ast  = Language.parse(@left_pattern)
        @right_ast = Language.parse(@right_pattern)
        kind == :inclusion ? inclusion(:left, :right) : equivalence
      rescue UnknownFeature => error
        Result.unknown(error.reason, error.detail)
      rescue StateLimit => error
        Result.unknown(:state_limit_exceeded, error.message)
      rescue ::Regexp::Parser::Error => error
        Result.unknown(:parse_error, error.message)
      end

      def inclusion(subset_key, superset_key)
        subset   = nfa(subset_key)
        superset = nfa(superset_key)

        product = Product.new(subset, superset, @alphabet, @max_product_states)
        witness = product.shortest_witness
        direction = subset_key == :left ? :left_to_right : :right_to_left

        if witness.nil?
          return include_result(subset, superset, direction)
        end

        counterexample = verify_witness(witness, subset_key)
        return counterexample if counterexample

        enumerated = Enumerator.check_inclusion(
          subset, superset, @alphabet, witness, @max_enumerated
        )
        return unknown_from_disagreement if enumerated.nil? || enumerated == false

        verify_witness(enumerated, subset_key) || unknown_from_disagreement
      rescue UnknownFeature => error
        Result.unknown(error.reason, error.detail)
      rescue StateLimit => error
        Result.unknown(:state_limit_exceeded, error.message)
      end

      def equivalence
        forward = inclusion(:left, :right)
        return forward unless forward.included?

        backward = inclusion(:right, :left)
        return backward unless backward.included?

        Result.equivalent(method: :product_automaton)
      end

      private

      def include_result(subset, superset, direction)
        enumerated = Enumerator.check_inclusion(
          subset, superset, @alphabet, nil, @max_enumerated
        )
        return unknown_from_disagreement unless enumerated.nil?

        Result.included(direction: direction, method: :product_automaton)
      end

      def nfa(key)
        @nfa_cache[key] ||= Compiler.new(
          ast(key), @alphabet, @max_states
        ).compile
      end

      def ast(key)
        key == :left ? @left_ast : @right_ast
      end

      def unknown_from_disagreement
        Result.unknown(
          :inconclusive,
          'product analysis and alphabet enumeration disagreed'
        )
      end

      def verify_witness(word, subset_key)
        in_subset = ruby_matches?(ast(subset_key), word)
        superset_key = subset_key == :left ? :right : :left
        in_superset = ruby_matches?(ast(superset_key), word)
        return nil unless in_subset && !in_superset

        if subset_key == :left
          Result.not_included(
            counterexample: word, direction: :left_to_right,
            accepted_by: :left, rejected_by: :right, method: :oracle
          )
        else
          Result.not_included(
            counterexample: word, direction: :right_to_left,
            accepted_by: :right, rejected_by: :left, method: :oracle
          )
        end
      end

      def ruby_matches?(expression_ast, word)
        regexp = anchored_regexp(expression_ast)
        return true if regexp.match?(word)
        return false unless word.end_with?("\n")
        return false unless trailing_newline_tolerant?(expression_ast)

        regexp.match?(word[0...-1])
      end

      def anchored_regexp(expression_ast)
        flags  = 0
        flags |= ::Regexp::IGNORECASE if expression_ast.options[:i]
        flags |= ::Regexp::MULTILINE  if expression_ast.options[:m]
        source = expression_ast.to_s
        @anchored_cache[[source, flags]] ||=
          ::Regexp.new('\A(?:' + source + ')\z', flags)
      end

      # Ruby drops a single final line break only when the pattern ends at the
      # top level with an unquantified $ or \Z anchor.
      def trailing_newline_tolerant?(expression_ast)
        @tolerant_cache[expression_ast] ||= begin
          last = expression_ast.expressions.last
          !last.nil? && !last.quantifier &&
            (last.is_a?(::Regexp::Expression::Anchor::EndOfLine) ||
             last.is_a?(::Regexp::Expression::Anchor::EndOfStringOrBeforeEndOfLine))
        end
      end
    end

    class << self
      def parse(pattern)
        case pattern
        when ::Regexp, String then ::Regexp::Parser.parse(pattern)
        else raise ArgumentError, 'patterns must be a Regexp or a String'
        end
      end

      def normalize_alphabet(alphabet)
        chars = Array(alphabet).map(&:to_s)
        if chars.empty? || chars.any? { |char| char.length != 1 }
          raise ArgumentError,
            'alphabet must be a non-empty array of single characters'
        end

        chars.uniq.sort_by(&:ord)
      end
    end
  end

  # Checks whether every alphabet string accepted by +pattern_left+ is also
  # accepted by +pattern_right+.
  #
  # Returns a Regexp::Parser::Language::Result:
  #
  #   result = Regexp::Parser.includes?(/a+/, /[ab]+/, %w[a b])
  #   result.included?   # => true
  #   result.proven?     # => true
  #
  # If inclusion is disproved, +result.counterexample+ is the shortest,
  # lexicographically smallest such string, and +result.direction+ and
  # +result.accepted_by+/+result.rejected_by+ identify the sides.
  # Unsupported features yield +result.unknown?+ and never a guessed answer.
  def self.includes?(pattern_left, pattern_right, alphabet, **kwargs)
    Language.analyze_inclusion(pattern_left, pattern_right, alphabet, **kwargs)
  end

  class << self
    alias_method :language_includes?, :includes?
  end

  # Checks language equivalence over the alphabet. Either proves it or
  # returns the shortest distinguishing counterexample and its direction.
  def self.equivalent?(pattern_left, pattern_right, alphabet, **kwargs)
    Language.analyze_equivalence(pattern_left, pattern_right, alphabet, **kwargs)
  end

  class << self
    alias_method :language_equivalent?, :equivalent?
  end
end

