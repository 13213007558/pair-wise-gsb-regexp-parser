# frozen_string_literal: true

require_relative 'nfa'

class Regexp::Parser
  module Language
    # Compiles a parsed regular expression (restricted subset) into an NFA.
    #
    # Supported: character sets (including ranges, intersections, POSIX
    # classes and Unicode properties), concatenation, alternation, groups
    # (passive, capturing, atomic, options), all greedy/reluctant/possessive
    # quantifiers including bounded intervals, literal escapes and the \A,
    # \G, \z, \Z, ^ and $ anchors.
    #
    # Unsupported (raises UnknownFeature, yielding an +unknown+ result):
    # backreferences, recursive/subpattern calls, conditionals, lookarounds
    # and other assertions, \K, the absence group, \b/\B, \R and \X, and
    # multi-codepoint escape lists. Case-insensitive patterns whose folding
    # is not one-to-one on the alphabet are also rejected rather than
    # approximated.
    class Compiler
      def initialize(ast, alphabet, max_states)
       @ast = ast
        @alphabet = alphabet
        @max_states = max_states
        @nfa = NFA.new
        @oracle = Oracle.new(ast, alphabet)
      end

      def compile
        check_case_folding! if @ast.options[:i] || has_case_option?(@ast)

        fragment = compile_expression(@ast)
        @nfa.start  = fragment.start
        @nfa.accept = fragment.accept
        @nfa.finite = fragment.finite
        @nfa.max_length = fragment.max_length
        @nfa.multiline = @ast.options[:m] == true
        @nfa.trailing_tolerant = @ast.expressions.any? &&
        tolerant_anchor?(@ast.expressions.last)
        @nfa
      end

      private

      # -- case folding safety ------------------------------------------------

      def has_case_option?(expression)
        return true if expression.respond_to?(:i?) && expression.i?
        return false unless expression.respond_to?(:expressions)

      expression.expressions.any? { |child| has_case_option?(child) }
      end

      # Full case folds can turn one code point into several (e.g.
      # \u1E9E -> 'ss') and several into one (ffi ligatures). Both break
      # the single-character transition model; require every possible fold
      # within the alphabet to remain a one-character fold.
      def check_case_folding!
        @alphabet.each do |char|
          if char.upcase.length > 1 || char.swapcase.length > 1
            raise UnknownFeature.new(:multicharacter_case_fold, char.inspect)
          end
        end

        chars = literal_chars(@ast)
        chars.each_with_index do |char, index|
          if char.upcase.length > 1 || char.swapcase.length > 1
            raise UnknownFeature.new(:multicharacter_case_fold, char.inspect)
          end
          (1..3).each do |length|
            next if index + length > chars.length
            probe  = chars[index, length].join
            folded = probe.upcase
            next unless folded.length > length
            if @alphabet.any? { |candidate| candidate.upcase == folded }
              raise UnknownFeature.new(:multicharacter_case_fold, probe.inspect)
            end
          end
        end
      end

      def literal_chars(expression, result = [])
        case expression
        when ::Regexp::Expression::Literal
          result.concat(expression.text.chars)
        when ::Regexp::Expression::EscapeSequence::CodepointList
          result.concat(expression.chars)
        end
        if expression.respond_to?(:expressions)
        expression.expressions.each { |child| literal_chars(child, result) }
        end
        result
      end

      # -- expression compilation ---------------------------------------------

      def compile_expression(expression)
        fragment =
        case expression
        when ::Regexp::Expression::Root,
          ::Regexp::Expression::Alternative
          compile_sequence(expression)
        when ::Regexp::Expression::Group::Passive,
          ::Regexp::Expression::Group::Capture,
          ::Regexp::Expression::Group::Named,
          ::Regexp::Expression::Group::Atomic,
          ::Regexp::Expression::Group::Options
          compile_sequence(expression)
        when ::Regexp::Expression::Group::Comment
          empty_fragment
        when ::Regexp::Expression::Alternation
          compile_alternation(expression)
        when ::Regexp::Expression::Literal
          compile_literal(expression)
        when ::Regexp::Expression::Anchor::Base
          compile_anchor(expression)
        when ::Regexp::Expression::CharacterSet
          class_fragment(expression)
        when ::Regexp::Expression::CharacterType::Base
          compile_character_type(expression)
        when ::Regexp::Expression::EscapeSequence::Base
          compile_escape(expression)
        when ::Regexp::Expression::UnicodeProperty::Base,
          ::Regexp::Expression::PosixClass
          class_fragment(expression)
        when ::Regexp::Expression::FreeSpace
          empty_fragment
        else
          raise_unsupported(expression)
        end
        apply_quantifier!(fragment, expression)
      end

      def compile_sequence(container)
      fragments = container.expressions.map { |child| compile_expression(child) }
        join_fragments(fragments)
      end

      def join_fragments(fragments)
        return empty_fragment if fragments.empty?

        fragments.each_cons(2) do |left, right|
          @nfa.add_edge(left.accept, right.start)
        end
        states = fragments.flat_map(&:states).uniq
        finite     = fragments.all?(&:finite)
        max_length = finite ? fragments.sum(&:max_length) : nil
        NFA::Fragment.new(
        fragments.first.start, fragments.last.accept, states, finite, max_length
        )
      end

      def compile_alternation(alternation)
        alternatives = alternation.alternatives.map do |alternative|
          compile_expression(alternative)
        end
        start  = add_state
        accept = add_state
        states = [start, accept]
        finite = true
        lengths = []
        alternatives.each do |fragment|
          @nfa.add_edge(start, fragment.start)
          @nfa.add_edge(fragment.accept, accept)
          states.concat(fragment.states)
          finite &&= fragment.finite
          lengths << fragment.max_length if fragment.finite
        end
        max_length = finite ? lengths.max : nil
        NFA::Fragment.new(start, accept, states, finite, max_length)
      end

      # -- atoms ---------------------------------------------------------------

      def compile_literal(expression)
        fragments = expression.text.chars.map do |char|
          labels = labels_for_literal(char, expression.i?)
          char_fragment(labels)
        end
        join_fragments(fragments)
      end

      def labels_for_literal(char, case_insensitive)
        if case_insensitive
          @alphabet.select do |candidate|
            @oracle.literal_match?(candidate, char, true)
          end
        elsif @alphabet.include?(char)
          [char]
        else
          []
        end
      end

      def compile_character_type(expression)
        case expression.token
        when :linebreak
          raise UnknownFeature.new(:unsupported_construct, '\\R (linebreak)')
        when :xgrapheme
          raise UnknownFeature.new(:unsupported_construct, '\\X (extended grapheme)')
        else
          class_fragment(expression)
        end
      end

      def compile_escape(expression)
        case expression
        when ::Regexp::Expression::EscapeSequence::CodepointList
          join_fragments(
          expression.chars.map do |char|
            char_fragment(labels_for_literal(char, expression.i?))
          end
          )
        when ::Regexp::Expression::EscapeSequence::UTF8Hex
          raise UnknownFeature.new(:unsupported_construct, 'UTF-8 byte escape sequence')
        when ::Regexp::Expression::EscapeSequence::AbstractMetaControlSequence
          raise_unsupported(expression)
        else
          char = expression.respond_to?(:char) ? expression.char : expression.text
          char_fragment(labels_for_literal(char, expression.i?))
        end
      end

      def class_fragment(expression)
        labels = @oracle.labels_for(expression)
        char_fragment(labels)
      end

      def char_fragment(labels)
        start  = add_state
        accept = add_state
        sorted = (labels & @alphabet).sort_by(&:ord)
        @nfa.add_edge(start, accept, :char, sorted)
        NFA::Fragment.new(start, accept, [start, accept], true, 1)
      end

      # -- anchors -------------------------------------------------------------

      ANCHOR_GATES = {
        bos: :bos,
        bol: :bol,
        eol: :eol,
        eos: :z,
        eos_ob_eol: :Z
      }.freeze

      def compile_anchor(expression)
        kind = ANCHOR_GATES[expression.token]
        if kind.nil?
          raise UnknownFeature.new(:unsupported_anchor, expression.to_s)
        end

        start  = add_state
        accept = add_state
        gate_kind = anchor_gate(expression, kind)
        @nfa.add_edge(start, accept, gate_kind)
        NFA::Fragment.new(start, accept, [start, accept], true, 0)
      end

      # Outside multiline mode, ^ is only the start of the whole string and
      # $ only its end (the single optional trailing newline is handled at
      # acceptance time). Collapse them onto the string-boundary gates.
      def anchor_gate(expression, kind)
        case kind
        when :bol then expression.m? ? :bol : :bos
        when :eol then expression.m? ? :eol : :endline
        else kind
        end
      end

      # -- quantifiers ---------------------------------------------------------

      def apply_quantifier!(fragment, expression)
        quantifier = expression.quantifier
        return fragment if quantifier.nil?

        repeat(fragment, quantifier.min, max_of(quantifier))
      end

      def max_of(quantifier)
        quantifier.max == -1 ? nil : quantifier.max
      end

      def repeat(fragment, min, max)
      required = Array.new(min) { copy_fragment(fragment) }
        head = join_fragments(required) unless required.empty?
        return head if max == min

        if max.nil?
          repeat_unbounded(fragment, min, head)
        else
          repeat_bounded(fragment, min, max, head)
        end
      end

      def repeat_unbounded(fragment, min, head)
        if head
          # e.g. a{2,} or a+ with a mandatory part: loop its tail to its head
          @nfa.add_edge(head.accept, head.start)
          head.finite = false
          head.max_length = nil
          head
        else
          # e.g. a* or a?: one copy with a self-loop and a skip edge
          copy   = copy_fragment(fragment)
          start  = add_state
          accept = add_state
          @nfa.add_edge(start, copy.start)
          @nfa.add_edge(start, accept)
          @nfa.add_edge(copy.accept, copy.start)
          @nfa.add_edge(copy.accept, accept)
          NFA::Fragment.new(
          start, accept, [start, accept].concat(copy.states), false, nil
          )
        end
      end

      def repeat_bounded(fragment, min, max, head)
      copies = Array.new(max - min) { copy_fragment(fragment) }
        start  = add_state
        accept = add_state
        states = [start, accept]
        if head
          @nfa.add_edge(start, head.start)
          states.concat(head.states)
          previous = head.accept
        else
          previous = start
        end
        copies.each do |copy|
          @nfa.add_edge(previous, copy.start)
          @nfa.add_edge(previous, accept)
          states.concat(copy.states)
          previous = copy.accept
        end
        @nfa.add_edge(previous, accept)
        NFA::Fragment.new(
        start, accept, states.uniq, true, fragment.max_length * max
        )
      end

      # Duplicates the states and edges of a fragment so bounded repetitions
      # share no NFA state with other copies.
      def copy_fragment(fragment)
      mapping = fragment.states.map { |state| [state, add_state] }.to_h
        fragment.states.each do |state|
          @nfa.outgoing(state).each do |edge|
            next unless mapping.key?(edge.to)
            @nfa.add_edge(mapping[state], mapping[edge.to], edge.kind, edge.labels)
          end
        end
        NFA::Fragment.new(
        mapping[fragment.start], mapping[fragment.accept],
      fragment.states.map { |state| mapping[state] },
        fragment.finite, fragment.max_length
        )
      end

      # -- helpers -------------------------------------------------------------

      def empty_fragment
        start  = add_state
        accept = add_state
        @nfa.add_edge(start, accept)
        NFA::Fragment.new(start, accept, [start, accept], true, 0)
      end

      def add_state
        state = @nfa.add_state
        if @nfa.state_count > @max_states
          raise Language::StateLimit,
          'compiled NFA exceeds ' + @max_states.to_s + ' states'
        end
        state
      end

      # Ruby drops a single final line break only when the pattern ends at
      # its top level with an unquantified $ or \Z. A $ nested in a group,
      # alternation or repetition does not grant that tolerance.
      def tolerant_anchor?(expression)
        return false if expression.nil? || expression.quantifier
        expression.is_a?(::Regexp::Expression::Anchor::EndOfLine) ||
        expression.is_a?(::Regexp::Expression::Anchor::EndOfStringOrBeforeEndOfLine)
      end
      def raise_unsupported(expression)
        raise UnknownFeature.new(
          :unsupported_construct,
          expression.class.name.sub(/Regexp::Expression::/, '') + ' ' + expression.to_s.inspect
        )
      end
    end
  end
end
