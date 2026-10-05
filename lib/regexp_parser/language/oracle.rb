# frozen_string_literal: true

class Regexp::Parser
  module Language
    # Membership oracle for the one-character atoms of a compiled pattern.
    #
    # The language of a regular expression over a fixed finite alphabet is
    # determined entirely by which alphabet characters each character class
    # accepts. Rather than reimplementing ranges, intersections, POSIX
    # classes, properties and case folding, the exact fragment of the
    # original pattern is wrapped in an anchored single-character regexp and
    # evaluated by Ruby itself.
    class Oracle
      def initialize(ast, alphabet)
        @flags = 0
        @flags |= ::Regexp::IGNORECASE if ast.options[:i]
        @flags |= ::Regexp::MULTILINE  if ast.options[:m]
        @alphabet = alphabet
      @cache = {}
      end

      # Alphabet characters accepted by the given character-class-like
      # expression (sets, POSIX classes, properties, \d, \w and so on).
      # +dot_all+ controls whether a dot atom accepts line breaks.
      def labels_for(expression, dot_all: expression.m?)
        key = [expression.object_id, dot_all]
        @cache[key] ||= begin
          regexp = class_regexp(expression, expression.token == :dot, dot_all)
        @alphabet.select { |char| regexp.match?(char) }
        end
      end

      # Whether an alphabet character matches a literal in the given mode.
      def literal_match?(char, target, case_insensitive)
        if case_insensitive
        char.casecmp?(target) rescue char.downcase == target.downcase
        else
          char == target
        end
      end

      private

      def class_regexp(expression, is_dot, dot_all)
        flags = @flags
        flags |= ::Regexp::IGNORECASE if expression.i?
        flags &= ~::Regexp::IGNORECASE unless expression.i?
        if is_dot
          flags = dot_all ? flags | ::Regexp::MULTILINE : flags & ~::Regexp::MULTILINE
        end
        source = class_source(expression)
        ::Regexp.new('\A(?:' + source + ')\z', flags)
      end

      # A quantified set includes its quantifier in #to_s, but the class
      # atom is evaluated on its own single-character fragment.
      def class_source(expression)
        source = expression.to_s
        quantifier = expression.quantifier
        if quantifier && source.end_with?(quantifier.text)
          source[0...-quantifier.text.length]
        else
          source
        end
      end
    end
  end
end
