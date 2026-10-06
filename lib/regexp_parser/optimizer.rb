# frozen_string_literal: true

require_relative 'optimizer/charset'
require_relative 'optimizer/analyzer'

class Regexp::Parser
  # A conservative source-to-source optimizer. It only rewrites a regular
  # expression when static analysis over a finite alphabet proves that the
  # rewrite cannot change matching, MatchData ranges, named captures or
  # backreference behavior:
  #
  #   * greedy quantifiers are made possessive when the first character set
  #     of the quantified body is disjoint from its follow set;
  #   * non-capturing groups are made atomic when their body is locally
  #     backtrack-stable and the same disjointness condition holds.
  #
  # Patterns containing recursive subexpression calls (\g<...>, \g'...') are
  # returned unchanged. Unsupported constructs (backreferences, assertions
  # adjacent to a rewrite site, \K, conditionals, absence groups,
  # negated/intersected/unbounded character classes, \R, \X, properties, ...)
  # keep the affected site unchanged and are reported in +skipped+.
  module Optimizer
    Change = Struct.new(:kind, :location, :source, :target, :proof) do
      def to_h
        { kind: kind, location: location, source: source, target: target,
          proof: proof }
      end
    end

    Skip = Struct.new(:kind, :location, :source, :reason)

    Result = Struct.new(:original, :optimized, :changes, :skipped) do
      def changed?
        !changes.empty?
      end
    end

    class << self
      # Returns a Result whose +original+ and +optimized+ are Ruby regex
      # pattern strings (no new matching engine is introduced). Accepts a
      # Regexp or a pattern String, like Regexp::Parser.parse.
      # When given a Regexp, Result#to_regexp builds a Regexp with the same
      # options; String input uses the given/parsed options.
      def optimize(input, syntax = nil, options: nil)
        root = Regexp::Parser.parse(input, syntax, options: options)
        analyzer = Analyzer.new(root).analyze

        original_source = root.to_s

        if analyzer.recursive
          return unchanged(original_source, recursive_skip(root))
        end

        changes = apply(analyzer.candidates)
        skipped = analyzer.skipped.map do |skip|
          Skip.new(skip.kind, skip.location, skip.node.to_s, skip.reason)
        end
        result = Result.new(original_source, root.to_s, changes, skipped)
        define_regexp_builders(result, input, root)
        result
      end

      private

      def unchanged(source, skipped)
        Result.new(source, source, [], skipped)
      end

      def define_regexp_builders(result, input, root)
        base_options = if input.is_a?(::Regexp)
                         input.options
                       else
                         options_to_flags(root.options)
                       end
        result.singleton_class.send(:define_method, :to_regexp) do
          ::Regexp.new(optimized, base_options)
        end
        result.singleton_class.send(:define_method, :original_regexp) do
          ::Regexp.new(original, base_options)
        end
      end

      def options_to_flags(options)
        flags = 0
        flags |= ::Regexp::IGNORECASE if options[:i]
        flags |= ::Regexp::MULTILINE   if options[:m]
        flags |= ::Regexp::EXTENDED    if options[:x]
        flags
      end

      def recursive_skip(root)
        skips = []
        root.each_expression(include_self: true) do |node|
          next unless node.type == :backref &&
                      Analyzer::CALL_TOKENS.include?(node.token)
          skips << Skip.new(:recursion, node.starts_at, node.to_s,
                            'recursive subexpression call - the whole ' \
                            'pattern is left unchanged')
        end
        skips
      end

      # Possessivize first; atomic bodies depend on their inner greedy
      # quantifiers becoming possessive in the same pass.
      def apply(candidates)
        candidates.sort_by { |candidate| candidate.kind == :possessive ? 0 : 1 }
                  .map do |candidate|
          node = candidate.node
          if candidate.kind == :possessive
            before = node.to_s
            make_possessive(node)
            after = node.to_s
          else
            before = node.to_s
            make_atomic(node)
            after = node.to_s
          end
          Change.new(candidate.kind, candidate.location, before, after,
                     candidate.reason)
        end
      end

      def make_possessive(node)
        quantifier = node.quantifier
        base = quantifier.text[/\A[?*+]/]
        node.quantifier = Regexp::Expression::Quantifier.construct(
          token: quantifier.token, text: "#{base}+"
        )
      end

      def make_atomic(group)
        group.text = '(?>'
      end
    end
  end
end
