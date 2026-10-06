# frozen_string_literal: true

class Regexp::Parser
  class FiniteLanguage
    # @api private
    #
    # Translates a validated parser tree into an epsilon NFA (see NFA).
    class Compiler
      # The actual marker is defined on FiniteLanguage (NFA).

      def initialize(language, budget)
        @language = language
        @budget = budget
        @states = []
      end

      # @return [Array(Array<State>, State, State)] states, start, accept
      def compile(root)
        fragment = compile_top(root)
        fragment.accept.final = true
        mark_zero_width_anchors(@states, fragment.start)
        [@states, fragment.start, fragment.accept]
      end

      private

      # Entry of the top-level pattern: the last token may be a terminal
      # loose anchor, which gains the trailing-newline behavior.
      def compile_top(root)
        compile_sequence_node(root, terminal_suffix: true)
      end

      def spend(amount = 1)
        @budget -= amount
        raise BudgetExhausted, 'NFA compilation exceeded budget' if @budget.negative?
      end

      def new_state
        spend
        State.new(id: @states.length).tap { |state| @states << state }
      end

      def epsilon_fragment
        state = new_state
        Fragment.new(start: state, accept: state)
      end

      def char_fragment(atom)
        start = new_state
        accept = new_state
        start.ch_edges << [atom, accept]
        Fragment.new(start: start, accept: accept)
      end

      def chain(fragments)
        return epsilon_fragment if fragments.empty?

        fragments.each_cons(2) { |left, right| left.accept.eps << right.start }
        Fragment.new(start: fragments.first.start, accept: fragments.last.accept)
      end

      # Concatenates the direct children of any container-like node (root,
      # alternative, non-alternation group).
      # +terminal_suffix+ marks the top-level pattern/branch, where a loose
      # end anchor gains the Ruby trailing-newline shortcut ("foo\n").
      def compile_sequence_node(node, terminal_suffix: false)
        children = node.expressions
        fragments = children.each_with_index.map do |child, index|
          last = index == children.length - 1
          compile_node(child, terminal: terminal_suffix && last)
        end
        chain(fragments)
      end

      def compile_container(node)
        compile_sequence_node(node, terminal_suffix: false)
      end

      def compile_node(node, terminal: false)
        case node
        when Regexp::Expression::Alternation
          compile_alternation(node, terminal: terminal)
        when Regexp::Expression::Anchor::Base
          compile_anchor(node, terminal: terminal)
        when Regexp::Expression::Literal
          compile_literal(node)
        when Regexp::Expression::EscapeSequence::CodepointList
          compile_codepoint_list(node)
        when Regexp::Expression::EscapeSequence::Base
          quantify(node, char_fragment(atom_for(node, base_source(node))))
        when Regexp::Expression::CharacterType::Base,
             Regexp::Expression::CharacterSet,
             Regexp::Expression::UnicodeProperty::Base
          quantify(node, char_fragment(atom_for(node, member_source(node))))
        when Regexp::Expression::PosixClass
          quantify(node, char_fragment(atom_for(node, "[#{node.to_s}]")))
        when Regexp::Expression::Group::Comment,
             Regexp::Expression::FreeSpace
          epsilon_fragment
        when Regexp::Expression::Subexpression
          # roots, sequences, groups (capture/passive/atomic/options/named)
          inner = compile_sequence_node(node, terminal_suffix: false)
          quantify(node, inner)
        else
          raise UnsupportedFeature, "unsupported expression: #{node.class}"
        end
      end

      def compile_alternation(node, terminal:)
        start = new_state
        accept = new_state
        node.expressions.each do |alternative|
          branch = compile_sequence_node(alternative, terminal_suffix: terminal)
          start.eps << branch.start
          branch.accept.eps << accept
        end
        quantified_base = Fragment.new(start: start, accept: accept)
        quantify(node, quantified_base)
      end

      def compile_anchor(node, terminal:)
        anchor = new_state
        after = new_state
        case node
        when Regexp::Expression::Anchor::BeginningOfString,
             Regexp::Expression::Anchor::MatchStart
          anchor.start_gates << after
        when Regexp::Expression::Anchor::BeginningOfLine
          # multiline ^ is rejected during validation
          anchor.start_gates << after
        when Regexp::Expression::Anchor::EndOfString
          anchor.strict_end_gates << after
        when Regexp::Expression::Anchor::EndOfStringOrBeforeEndOfLine,
             Regexp::Expression::Anchor::EndOfLine
          # $ and \Z are end positions; the special trailing-newline case
          # ("foo\n" matches /foo$/) is handled by the engine, which knows
          # the total requested length. Keeping it out of the NFA means a
          # loose anchor inside a repetition cannot match halfway:
          # /(x\Z)*/ yields "" and "x", but never "xx".
          anchor.loose_end_gates << [after, false]
          add_terminal_newline_edge(anchor, after) if terminal
        end
        fragment = Fragment.new(start: anchor, accept: after)
        quantify(node, fragment)
      end

      # Adds the virtual trailing-newline edge for a terminal loose anchor.
      def add_terminal_newline_edge(anchor_state, target)
        bypass = new_state
        bypass.strict_end_gates << target
        marker = FiniteLanguage::TrailingNewlineAtom::INSTANCE
        anchor_state.ch_edges << [marker, bypass]
      end

      # Anchor states reachable from the NFA entry through zero-consuming
      # paths through epsilon and anchor gates at position 0. A trailing-newline
      # marker on such a state would let an empty-prefix match swallow a
      # newline, which Ruby does not do, so the engine suppresses it there.
      def mark_zero_width_anchors(states, start)
        reachable = {}
        pending = [start]
        until pending.empty?
          state = pending.pop
          next if reachable[state.id]

          reachable[state.id] = true
          pending.concat(state.eps)
          state.start_gates.each { |t, _term| pending << t }
          state.strict_end_gates.each { |t| pending << t }
          state.loose_end_gates.each { |t, _term| pending << t }
        end
        states.each do |state|
          next unless reachable[state.id]

          state.ch_edges.map! do |atom, target|
            if atom.equal?(FiniteLanguage::TrailingNewlineAtom::INSTANCE)
              marker = FiniteLanguage::ZeroWidthNewlineAtom.new(
                source: "\n", options: {}, literal: true
              )
              [marker, target]
            else
              [atom, target]
            end
          end
        end
      end

      def compile_literal(node)
        atoms = node.text.chars.map do |char|
          Atom.new(source: char, options: node.options, literal: true)
        end
        quantify(node, chain(atoms.map { |atom| char_fragment(atom) }))
      end

      def compile_codepoint_list(node)
        atoms = node.codepoints.map do |cp|
          Atom.new(source: cp.chr(Encoding::UTF_8), options: node.options,
                   literal: true)
        end
        quantify(node, chain(atoms.map { |atom| char_fragment(atom) }))
      end

      # Quantifiers only change the generated language; greedy and reluctant
      # modes are equivalent (possessive quantifiers are rejected upstream).
      def quantify(node, fragment)
        quantifier = node.quantifier
        return fragment unless quantifier

        min = quantifier.min
        max = quantifier.max # -1 means unbounded
        pieces = Array.new(min) { copy_fragment(fragment) }
        if max == -1
          pieces << star_fragment(fragment)
        elsif max > min
          (max - min).times do
            optional = copy_fragment(fragment)
            pieces << optional_fragment(optional)
          end
        end
        chain(pieces)
      end

      # Wraps a fragment so it may be skipped (the ? choice).
      def optional_fragment(fragment)
        start = new_state
        accept = new_state
        start.eps << fragment.start
        start.eps << accept
        fragment.accept.eps << accept
        Fragment.new(start: start, accept: accept)
      end

      # Wraps a fragment so it may be repeated any number of times (the *).
      def star_fragment(fragment)
        optional_fragment(loop_fragment(fragment))
      end

      def loop_fragment(fragment)
        copy = copy_fragment(fragment)
        copy.accept.eps << copy.start
        copy
      end

      # Deep-copies an NFA fragment so quantified subexpressions are
      # independent (Thompson construction).
      def copy_fragment(fragment)
        originals = {}
        collect(fragment.start, originals)
        collect(fragment.accept, originals)

        mapping = {}
        originals.each_value do |original|
          copy = new_state
          mapping[original.id] = [original, copy]
        end
        mapping.each_value do |(original, copy)|
          copy.eps.concat(original.eps.map { |target| mapping.fetch(target.id).last })
          copy.start_gates.concat(
            original.start_gates.map { |target| mapping.fetch(target.id).last }
          )
          copy.strict_end_gates.concat(
            original.strict_end_gates.map { |target| mapping.fetch(target.id).last }
          )
          copy.loose_end_gates.concat(
            original.loose_end_gates.map do |target, terminal|
              [mapping.fetch(target.id).last, terminal]
            end
          )
          copy.ch_edges.concat(
            original.ch_edges.map { |atom, target| [atom, mapping.fetch(target.id).last] }
          )
        end
        Fragment.new(start: mapping.fetch(fragment.start.id).last,
                     accept: mapping.fetch(fragment.accept.id).last)
      end

      def collect(state, found)
        return if found.key?(state.id)

        found[state.id] = state
        state.eps.each { |target| collect(target, found) }
        state.start_gates.each { |target| collect(target, found) }
        state.strict_end_gates.each { |target| collect(target, found) }
        state.loose_end_gates.each { |target, _terminal| collect(target, found) }
        state.ch_edges.each { |_atom, target| collect(target, found) }
      end

      def base_source(node)
        node.respond_to?(:to_s) ? node.to_s(:base) : node.text
      end

      def atom_for(node, source)
        Atom.new(source: source, options: effective_options(node), literal: false)
      end

      def member_source(node)
        if node.is_a?(Regexp::Expression::PosixClass)
          "[#{node.to_s(:base)}]"
        else
          node.to_s(:base)
        end
      end

      def effective_options(node)
        node.options
      end
    end
  end
end
