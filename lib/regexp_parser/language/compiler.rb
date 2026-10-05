# frozen_string_literal: true

class Regexp::Parser
  module Language
    class Compiler
      UnknownFeature = Class.new(StandardError)

      def self.compile(pattern, alphabet, state_limit)
        new(pattern, alphabet, state_limit).compile
      end

      def initialize(pattern, alphabet, state_limit)
        @pattern = pattern
        @alphabet = alphabet
        @state_limit = state_limit
        @root = nil
        @class_matcher_cache = {}
      end

      def compile
        @root = Regexp::Parser.parse(@pattern)
        validate!(@root)
        nfa = NFA.new(@state_limit)
        body = compile_node(@root, nfa)
        start = nfa.state
        prefix_entry = nfa.state
        prefix_loop = nfa.state
        pattern_start = nfa.state
        pattern_accept = nfa.state
        suffix = nfa.state

        nfa.epsilon(start, prefix_entry)
        nfa.epsilon(start, pattern_start)
        nfa.epsilon(pattern_start, body.start)
        nfa.epsilon(body.accept, pattern_accept)
        nfa.epsilon(pattern_accept, suffix)

        @alphabet.each do |character|
          nfa.char(prefix_entry, character, prefix_loop)
          nfa.char(prefix_loop, character, prefix_loop)
          nfa.char(prefix_loop, character, pattern_start)
          nfa.char(suffix, character, suffix)
        end

        {
          nfa: nfa,
          start: start,
          accept: suffix,
          prefix_loop: prefix_loop,
          pattern_accept: pattern_accept,
          root: @root
        }
      rescue StandardError => error
        { error: error }
      end

      private

      def validate!(node)
        case node
        when Regexp::Expression::Backreference::Base,
             Regexp::Expression::Conditional::Expression,
             Regexp::Expression::Conditional::Condition,
             Regexp::Expression::Keep::Mark,
             Regexp::Expression::Group::Absence,
             Regexp::Expression::Group::Atomic,
             Regexp::Expression::Assertion::Base
          unknown!(node)
        when Regexp::Expression::Anchor::WordBoundary,
             Regexp::Expression::Anchor::NonWordBoundary,
             Regexp::Expression::Anchor::MatchStart
          unknown!(node)
        when Regexp::Expression::CharacterType::ExtendedGrapheme,
             Regexp::Expression::CharacterType::Linebreak
          unknown!(node)
        when Regexp::Expression::EscapeSequence::Control,
             Regexp::Expression::EscapeSequence::Meta,
             Regexp::Expression::EscapeSequence::MetaControl,
             Regexp::Expression::EscapeSequence::UTF8Hex
          unknown!(node)
        end

        if node.quantified? && node.quantifier.possessive?
          unknown!(node)
        end

        return unless node.respond_to?(:expressions)
        node.expressions.each { |child| validate!(child) }
      end

      def compile_node_without_quantifier(node, nfa)
        case node
        when Regexp::Expression::Root
          compile_children(node, nfa)
        when Regexp::Expression::Alternation
          compile_alternation(node, nfa)
        when Regexp::Expression::Alternative
          compile_children(node, nfa)
        when Regexp::Expression::Group::Passive,
             Regexp::Expression::Group::Capture,
             Regexp::Expression::Group::Named
          compile_children(node, nfa)
        when Regexp::Expression::Group::Options
          compile_children(node, nfa)
        when Regexp::Expression::Anchor::BeginningOfLine,
             Regexp::Expression::Anchor::BeginningOfString,
             Regexp::Expression::Anchor::EndOfLine,
             Regexp::Expression::Anchor::EndOfString,
             Regexp::Expression::Anchor::EndOfStringOrBeforeEndOfLine
          compile_anchor(node, nfa)
        when Regexp::Expression::FreeSpace
          nfa.fragment
        when Regexp::Expression::CharacterSet
          compile_character_set(node, nfa)
        when Regexp::Expression::CharacterType::Base
          compile_class_node(node, nfa)
        when Regexp::Expression::PosixClass
          compile_class_node(node, nfa)
        when Regexp::Expression::UnicodeProperty::Base
          compile_class_node(node, nfa)
        when Regexp::Expression::EscapeSequence::CodepointList
          compile_codepoint_list(node, nfa)
        when Regexp::Expression::EscapeSequence::Base
          compile_strings(expand_literal(node.char, node), node, nfa)
        when Regexp::Expression::Literal
          compile_literal(node, nfa)
        else
          unknown!(node)
        end

      end

      def compile_node(node, nfa)
        fragment = compile_node_without_quantifier(node, nfa)
        apply_quantifier!(fragment, node, nfa)
      end

      def compile_children(node, nfa)
        nfa.concatenate(node.expressions.map { |child| compile_node(child, nfa) })
      end

      def compile_alternation(node, nfa)
        nfa.union(node.alternatives.map { |alternative| compile_node(alternative, nfa) })
      end

      def compile_anchor(node, nfa)
        fragment = NFA::Fragment.new(nfa.state, nfa.state)
        case node
        when Regexp::Expression::Anchor::BeginningOfLine
          nfa.start_boundary(fragment.start, node.multiline? ? :line : :bos, fragment.accept)
        when Regexp::Expression::Anchor::BeginningOfString
          nfa.start_boundary(fragment.start, :bos, fragment.accept)
        when Regexp::Expression::Anchor::EndOfLine
          nfa.end_boundary(fragment.start, node.multiline? ? :line_end : :string_end, fragment.accept)
        when Regexp::Expression::Anchor::EndOfString
          nfa.end_boundary(fragment.start, :eos, fragment.accept)
        when Regexp::Expression::Anchor::EndOfStringOrBeforeEndOfLine
          nfa.end_boundary(fragment.start, :eos_or_final_newline, fragment.accept)
        end
        fragment
      end

      def compile_literal(node, nfa)
        fragments = characters(node.text).map do |character|
          nfa.union(expand_literal(character, node).map do |string|
            fragment_for_string(string, nfa)
          end)
        end
        nfa.concatenate(fragments)
      end

      def compile_codepoint_list(node, nfa)
        fragments = node.chars.map do |character|
          nfa.union(expand_literal(character, node).map do |string|
            fragment_for_string(string, nfa)
          end)
        end
        nfa.concatenate(fragments)
      end

      def compile_strings(strings, node, nfa)
        strings = Array(strings).select { |string| string_within_alphabet?(string) }
        nfa.union(strings.map { |string| fragment_for_string(string, nfa) })
      end

      def compile_class_node(node, nfa)
        strings = class_strings(node)
        unknown!(node) if strings.empty?
        compile_strings(strings, node, nfa)
      end

      def compile_character_set(node, nfa)
        if node.expressions.any? { |child| child.is_a?(Regexp::Expression::CharacterSet::Intersection) }
          compile_strings(intersection_strings(node), node, nfa)
        elsif node.negative?
          compile_strings(class_strings(node), node, nfa)
        else
          compile_strings(positive_set_strings(node), node, nfa)
        end
      end

      def positive_set_strings(node)
        intersection = node.expressions.detect do |child|
          child.is_a?(Regexp::Expression::CharacterSet::Intersection)
        end
        return intersection_strings(node) if intersection

        strings = []
        node.expressions.each do |child|
          if child.is_a?(Regexp::Expression::CharacterSet::Intersection)
            next
          elsif child.is_a?(Regexp::Expression::CharacterSet::Range)
            strings.concat(range_strings(child))
          elsif child.respond_to?(:negative?) && child.negative?
            strings.concat(@alphabet.reject { |character| class_matcher(child).match?(character) })
          elsif child.is_a?(Regexp::Expression::CharacterSet)
            strings.concat(positive_set_strings(child))
          else
            strings.concat(class_strings(child))
          end
        end
        strings.uniq
      end

      def intersection_strings(node)
        intersection = node.expressions.detect do |child|
          child.is_a?(Regexp::Expression::CharacterSet::Intersection)
        end
        strings = class_strings(intersection.sequences[0])
        intersection.sequences[1..-1].to_a.each do |sequence|
          allowed = class_strings(sequence)
          strings = strings.select { |string| allowed.include?(string) }
        end
        strings = @alphabet.reject { |character| strings.include?(character) } if node.negative?
        strings
      end

      def range_strings(range)
        from = range_character(range.expressions[0])
        to = range_character(range.expressions[1])
        unknown!(range) unless from && to && from.ord <= to.ord
        @alphabet.select { |character| character.ord >= from.ord && character.ord <= to.ord }
      end

      def range_character(node)
        if node.is_a?(Regexp::Expression::EscapeSequence::Base)
          node.char
        elsif node.is_a?(Regexp::Expression::Literal) && node.text.length == 1
          node.text
        end
      end

      def class_strings(node)
        if node.is_a?(Regexp::Expression::Subexpression) &&
           !node.is_a?(Regexp::Expression::CharacterSet::Range)
          if node.is_a?(Regexp::Expression::CharacterSet)
            strings = node.expressions.any? do |child|
              child.is_a?(Regexp::Expression::CharacterSet::Intersection)
            end ? intersection_strings(node) : positive_set_strings(node)
            return node.negative? ? @alphabet - strings : strings
          end
          return compile_sequence_class_strings(node)
        end

        if node.negative? && !node.is_a?(Regexp::Expression::CharacterType::Base)
          return @alphabet.reject { |character| class_matcher(node).match?(character) }
        end

        matcher = class_matcher(node)
        matched = @alphabet.select { |character| matcher.match?(character) }
        return matched unless node.case_insensitive?
        matched + extra_fold_strings(matcher)
      end

      def compile_sequence_class_strings(node)
        strings = positive_set_strings(node)
        node.expressions.each do |child|
          unknown!(child) unless child.is_a?(Regexp::Expression::CharacterSet) ||
                                 child.is_a?(Regexp::Expression::CharacterSet::Range) ||
                                 child.is_a?(Regexp::Expression::CharacterType::Base) ||
                                 child.is_a?(Regexp::Expression::PosixClass) ||
                                 child.is_a?(Regexp::Expression::UnicodeProperty::Base) ||
                                 child.is_a?(Regexp::Expression::EscapeSequence::Base) ||
                                 child.is_a?(Regexp::Expression::Literal)
        end
        strings
      end

      def class_matcher(node)
        @class_matcher_cache[node] ||= begin
          source = class_source(node)
          flags = node_flags(node)
          Regexp.new("\\A#{source}\\z", flags)
        end
      end

      def node_flags(node)
        flags = 0
        flags |= Regexp::IGNORECASE if node.case_insensitive?
        flags |= Regexp::MULTILINE if node.multiline?
        flags |= Regexp::EXTENDED if node.free_spacing?
        flags |= Regexp::NOENCODING if node.options[:d]
        flags |= Regexp::FIXEDENCODING if node.options[:a] || node.options[:u]
        flags
      end

      def class_source(node)
        if node.is_a?(Regexp::Expression::CharacterSet)
          node.to_s(:base)
        elsif node.is_a?(Regexp::Expression::CharacterType::Any)
          '.'
        elsif node.is_a?(Regexp::Expression::CharacterType::Base) ||
              node.is_a?(Regexp::Expression::PosixClass) ||
              node.is_a?(Regexp::Expression::UnicodeProperty::Base)
          "[#{node.to_s(:base)}]"
        elsif node.is_a?(Regexp::Expression::Literal)
          Regexp.escape(node.to_s(:base))
        else
          node.to_s(:base)
        end
      end

      def fragment_for_string(string, nfa)
        states = [nfa.state]
        string.each_char { states << nfa.state }
        fragment = NFA::Fragment.new(states.first, states.last)
        string.each_char.with_index do |character, index|
          nfa.char(states[index], character, states[index + 1])
        end
        fragment
      end

      def single_character(node)
        strings = class_strings(node)
        strings.first if strings.length == 1 && strings.first.length == 1
      end

      def expand_literal(character, node)
        return [character] unless node.case_insensitive?
        matcher = Regexp.new("\\A#{Regexp.escape(character)}\\z", Regexp::IGNORECASE)
        [character] + @alphabet.select { |candidate| matcher.match?(candidate) } +
          extra_fold_strings(matcher)
      end

      def extra_fold_strings(matcher)
        candidates = fold_candidates
        candidates.select { |string| string.length > 1 && matcher.match?(string) }
      end

      def fold_candidates
        @fold_candidates ||= begin
          singles = @alphabet.uniq
          pairs = singles.product(singles).map(&:join)
          triples = singles.product(singles).product(singles).map do |pair, single|
            [pair[0], pair[1], single].join
          end
          (pairs + triples).uniq
        end
      end

      def apply_quantifier!(fragment, node, nfa)
        return fragment unless node.quantified?
        quantifier = node.quantifier
        max = quantifier.max < 0 ? nil : quantifier.max
        nfa.repeat(fragment, quantifier.min, max)
      end

      def characters(string)
        string.each_char.to_a
      end

      def string_within_alphabet?(string)
        string.each_char.all? { |character| @alphabet.include?(character) }
      end

      def unknown!(node)
        name = node.class.name.sub('Regexp::Expression::', '')
        raise UnknownFeature, "unsupported regular expression feature: #{name} #{node.to_s.inspect}"
      end
    end
  end
end
