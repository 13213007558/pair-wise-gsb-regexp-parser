# frozen_string_literal: true

class Regexp::Parser
  module Optimizer
    # Static analysis for the conservative optimizer.
    #
    # For every expression it derives, over a finite character alphabet:
    #   * first    - codepoints its first consumed character can be
    #   * nullable - whether it may consume nothing
    #   * hard     - whether it contains a construct the analyzer refuses to
    #                reason about (recursive calls, backreferences,
    #                assertions, \K, conditionals, absence groups, \R/\X,
    #                unbounded/unsupported character classes, ...). A hard
    #                node and all of its ancestors are never rewrite targets.
    #
    # It then propagates follow sets: characters that may be consumed
    # immediately after an expression in some parse of the whole pattern.
    #
    # Safety criterion for making a greedy quantifier possessive:
    #   follow(body) & first(body) == empty.
    # Every abandoned iteration boundary repeats a first(body) character;
    # if such a character can never legitimately follow the body, the greedy
    # and possessive engines accept the same strings with identical captures.
    class Analyzer
      # +nullable+ respects an enclosing zero-minimum quantifier (b? can
      # match empty); +body_nullable+ describes the body itself (b? taken
      # as the repeated body still consumes a 'b' on the iteration that
      # matches), which is what the quantifier tail analysis needs.
      Summary = Struct.new(:first, :nullable, :body_nullable, :hard)
      Candidate = Struct.new(:node, :kind, :first, :follow, :reason) do
        def location
          node.starts_at
        end
      end
      Skip = Struct.new(:node, :kind, :reason) do
        def location
          node.starts_at
        end
      end

      EXPRESSION    = Regexp::Expression
      SEQUENCE_TYPES = [
        EXPRESSION::Root,
        EXPRESSION::Group::Base,
        EXPRESSION::Group::Options,
        EXPRESSION::Sequence,
      ].freeze

      POSSESSIVE_PROOF = 'greedy body is non-nullable and its first ' \
        'character set is disjoint from every character that can follow it'.freeze
      ATOMIC_PROOF = 'body is backtrack-stable (pairwise disjoint ' \
        'alternatives and only possessivizable inner quantifiers) and its ' \
        'first character set is disjoint from every character that can ' \
        'follow it'.freeze

      attr_reader :candidates, :skipped, :recursive

      def initialize(root)
        @root = root
        @summaries = {}
        @follows = {}
        @candidates = []
        @skipped = []
        @recursive = false
      end

      def analyze
        detect_recursion(@root)
        summarize(@root)
        propagate(@root, Charset.set([]))
        collect_atomic(@root)
        self
      end

      # ----- postorder: first / nullable / hard -------------------------------

      def summarize(node)
        @summaries[node] ||= build_summary(node)
      end

      def build_summary(node)
        if node.is_a?(EXPRESSION::CharacterSet)
          first, hard = set_summary(node)
          return Summary.new(first, false, false, hard)
        end

        children = container?(node) ? node.expressions : []
        child_summaries = children.map { |child| summarize(child) }

        first, body_nullable, hard =
          if node.is_a?(EXPRESSION::Group::Options) && node.token == :options_switch
            [Charset.set([]), true, false] # (?i)/(?-m): zero-width flag switch
          elsif sequence_type?(node)
            summarize_sequence(child_summaries)
          elsif node.is_a?(EXPRESSION::Alternation)
            summarize_alternation(child_summaries)
          elsif node.is_a?(EXPRESSION::Group::Absence) ||
                node.is_a?(EXPRESSION::Conditional::Expression)
            [Charset::ANY, true, true]
          elsif node.is_a?(EXPRESSION::Assertion::Base)
            [Charset.set([]), true, true]
          elsif node.is_a?(EXPRESSION::Anchor::Base)
            [Charset.set([]), true, true]
          elsif node.is_a?(EXPRESSION::Keep)
            [Charset::ANY, true, true]
          elsif node.is_a?(EXPRESSION::FreeSpace)
            [Charset.set([]), true, false]
          elsif children.empty?
            summarize_terminal(node)
          else
            summarize_sequence(child_summaries)
          end

        # a quantifier with a zero minimum makes its whole target nullable
        nullable = body_nullable ||
                   (node.quantified? && node.quantifier.min.zero?)

        Summary.new(first, nullable, body_nullable, hard)
      end

      def set_summary(set_node)
        codepoints = set_codepoints(set_node)
        return [Charset::ANY, true] if codepoints.nil?

        first = codepoints.map { |cp| expand_case(cp, set_node) }
        [first.reduce(Charset.set([])) { |set, cp_set| set | cp_set }, false]
      end

      def summarize_sequence(summaries)
        first = Charset.set([])
        summaries.each do |summary|
          first = Charset.union(first, summary.first)
          # Within a sequence the whole child (including its quantifier)
          # may be skippable, e.g. c? in (c?|ab).
          break unless summary.nullable
        end
        [first, summaries.all?(&:nullable), summaries.any?(&:hard)]
      end

      def summarize_alternation(summaries)
        first = summaries.reduce(Charset.set([])) do |set, summary|
          Charset.union(set, summary.first)
        end
        [first, summaries.any?(&:nullable), summaries.any?(&:hard)]
      end

      # ----- terminals ----------------------------------------------------------

      def summarize_terminal(node)
        codepoints = terminal_codepoints(node)
        return [Charset::ANY, false, true] if codepoints.nil?

        first = codepoints.map { |cp| expand_case(cp, node) }
        [first.reduce(:|) || Charset.set([]), false, false]
      end

      # nil  => unknown alphabet (ANY / hard)
      # []   => consumes no character (defensive; should not occur here)
      def terminal_codepoints(node)
        case node
        when EXPRESSION::Literal
          first = node.text.each_codepoint.first
          first ? [first] : []
        when EXPRESSION::EscapeSequence::Literal
          [node.token == :backslash ? 0x5C : node.text[1].ord]
        when EXPRESSION::EscapeSequence::Bell        then [0x07]
        when EXPRESSION::EscapeSequence::Backspace   then [0x08]
        when EXPRESSION::EscapeSequence::AsciiEscape then [0x1B]
        when EXPRESSION::EscapeSequence::FormFeed    then [0x0C]
        when EXPRESSION::EscapeSequence::Newline     then [0x0A]
        when EXPRESSION::EscapeSequence::Return      then [0x0D]
        when EXPRESSION::EscapeSequence::Tab         then [0x09]
        when EXPRESSION::EscapeSequence::VerticalTab then [0x0B]
        when EXPRESSION::EscapeSequence::Octal
          [node.text[/\d+/].to_i(8)]
        when EXPRESSION::EscapeSequence::Hex, EXPRESSION::EscapeSequence::Codepoint
          [node.text[/[0-9a-fA-F]+/].to_i(16)]
        when EXPRESSION::EscapeSequence::CodepointList
          [node.text[/[0-9a-fA-F ]+/].split.first.to_i(16)]
        when EXPRESSION::CharacterSet
          set_codepoints(node)
        else
          nil
        end
      end

      def set_codepoints(set_node)
        return nil if set_node.negated?

        codepoints = []
        set_node.expressions.each do |child|
          case child
          when EXPRESSION::CharacterSet::Range
            from = member_codepoint(child.expressions.first)
            to   = member_codepoint(child.expressions.last)
            return nil if from.nil? || to.nil? || to < from
            codepoints.concat((from..to).to_a)
          when EXPRESSION::Literal
            codepoints << child.text.ord
          else
            return nil # nested sets, types, properties, posix classes, ...
          end
        end
        codepoints
      end

      def member_codepoint(node)
        cps = terminal_codepoints(node)
        return nil if cps.nil? || cps.length != 1
        cps.first
      end

      def expand_case(codepoint, node)
        if node.options && node.options[:i]
          Charset.case_partners(codepoint)
        else
          Charset.set([codepoint])
        end
      end

      # ----- recursion -----------------------------------------------------------

      CALL_TOKENS = %i[
        number_call number_rel_call name_call
        number_recursion_ref name_recursion_ref
      ].freeze
      public_constant :CALL_TOKENS

      def detect_recursion(node)
        if node.type == :backref && CALL_TOKENS.include?(node.token)
          @recursive = true
        end
        return unless container?(node)
        node.each { |child| detect_recursion(child) }
      end

      # ----- preorder: follow propagation --------------------------------------

      def propagate(node, incoming, exit_follow = incoming)
        @follows[node] = incoming

        if sequence_type?(node)
          walk_children(node, incoming, exit_follow)
        elsif node.is_a?(EXPRESSION::Alternation) ||
              node.is_a?(EXPRESSION::Conditional::Expression)
          node.expressions.each { |alt| propagate(alt, incoming, exit_follow) }
        elsif node.is_a?(EXPRESSION::Group::Atomic)
          # backtracking cannot cross an atomic boundary; only the group's
          # own follow is visible to its contents
          walk_children(node, incoming, incoming)
        elsif opaque?(node)
          walk_opaque(node)
        end

        collect_possessive(node, incoming)
      end

      def walk_children(container, incoming, exit_follow)
        expressions = container.expressions
        expressions.each_with_index do |child, index|
          suffix = follow_prefix(expressions, index + 1, incoming)
          child_exit = exit_through_tail(expressions, index + 1, incoming, exit_follow)
          propagate_quantified(child, suffix, child_exit)
        end
      end

      # First characters reachable when control exits through the suffix
      # beginning at expressions[index], skipping any leading run of
      # nullable siblings (a skippable tail of a quantifier), then falling
      # through to the container's own exit follow.
      def exit_through_tail(expressions, index, incoming, exit_follow)
        probe = index
        while probe < expressions.length
          exp = expressions[probe]
          # an atomic group is a backtracking barrier even when nullable
          break if exp.is_a?(EXPRESSION::Group::Atomic)
          break unless summarize(exp).body_nullable
          probe += 1
        end
        after_tail = follow_prefix(expressions, probe,
                                  Charset.union(incoming, exit_follow))
        probe > index ? Charset.union(follow_prefix(expressions, index, incoming),
                                      after_tail) : after_tail
      end

      def propagate_quantified(node, suffix, exit_follow)
        if node.quantified?
          @follows[node] = suffix
          candidate_follow = body_exit_follow(node, suffix, exit_follow)
          collect_possessive(node, candidate_follow)
          body_follow =
            if node.quantifier.possessive?
              suffix # possessive quantifiers never feed the suffix back in
            else
              # after one iteration either another iteration starts or the
              # suffix begins
              Charset.union(summarize(node).first, candidate_follow)
            end
          enter_target(node, body_follow, candidate_follow)
        else
          propagate(node, suffix, exit_follow)
        end
      end

      # Extends exit_follow with a nullable tail *inside* a quantified
      # body; e.g. in (?:c*b?a*)cc, c* may stop before the skippable
      # b?a* tail, so its proof set contains b, a and c.
      def body_exit_follow(node, suffix, exit_follow)
        children = container?(node) ? node.expressions : nil
        return Charset.union(suffix, exit_follow) if children.nil? || children.empty?

        tail_index = children.length
        tail_index -= 1 while tail_index > 0 &&
                            summarize(children[tail_index - 1]).body_nullable
        return Charset.union(suffix, exit_follow) if tail_index == children.length

        exit_through_tail(children, tail_index, suffix, exit_follow)
      end

      # When computing a skippable nullable tail for a quantifier in an
      # enclosing sequence, the tail run stops at an atomic group: control
      # cannot leave that group and come back, so its possible emptiness
      # does not expose the outer suffix to the quantifier.

      def enter_target(node, body_follow, exit_follow)
        if sequence_type?(node)
          walk_children(node, body_follow, exit_follow)
        elsif node.is_a?(EXPRESSION::Alternation) ||
              node.is_a?(EXPRESSION::Conditional::Expression)
          node.expressions.each { |alt| propagate(alt, body_follow, exit_follow) }
        elsif opaque?(node)
          walk_opaque(node)
        end
      end

      def walk_opaque(node)
        return unless container?(node)
        node.expressions.each { |child| propagate(child, Charset::ANY) }
      end

      # First characters potentially consumed starting at expressions[index],
      # skipping zero-width (nullable) expressions; falls through to the
      # container's own follow when the remaining suffix is nullable.
      def follow_prefix(expressions, index, after_container)
        result = Charset.set([])
        (index...expressions.length).each do |i|
          exp = expressions[i]
          result = Charset.union(result, prefix_first(exp))
          # The sequence can continue past anything that is nullable
          # including a zero-minimum quantifier (e.g. an optional group).
          return result unless summarize(exp).nullable
        end
        Charset.union(result, after_container)
      end

      def prefix_first(exp)
        case exp
        when EXPRESSION::Assertion::NegativeLookahead,
             EXPRESSION::Assertion::NegativeLookbehind,
             EXPRESSION::Anchor::Base, EXPRESSION::Keep
          Charset::ANY
        when EXPRESSION::Assertion::Lookahead
          if contains_opaque?(exp)
            Charset::ANY
          else
            inner = exp.expressions.first
            inner ? summarize(inner).first : Charset.set([])
          end
        when EXPRESSION::Assertion::Lookbehind
          Charset.set([]) # zero-width, consumes no character after here
        else
          contains_opaque?(exp) ? Charset::ANY : summarize(exp).first
        end
      end

      # True for absence groups (and other backtrack-affecting opaque
      # constructs) anywhere in the subtree - their influence on the engine
      # is not captured by the plain first-character set.
      def contains_opaque?(node)
        return true if node.is_a?(EXPRESSION::Group::Absence) ||
                       node.is_a?(EXPRESSION::Keep) ||
                       node.is_a?(EXPRESSION::Assertion::Base) ||
                       node.is_a?(EXPRESSION::Assertion::NegativeLookahead) ||
                       node.is_a?(EXPRESSION::Assertion::NegativeLookbehind)
        return false unless container?(node)
        node.expressions.any? { |child| contains_opaque?(child) }
      end

      # ----- candidate collection ----------------------------------------------

      def collect_possessive(node, follow)
        return unless node.quantified? && node.quantifier.greedy?
        q = node.quantifier
        # Ruby has no possessive interval syntax ({n,m}+ is parsed as
        # {n,m} followed by an unrelated +), and wrapping in (?:...)+ would
        # change the bounded repetition count. Intervals are left as-is.
        return if q.token == :interval
        return if inside_assertion?(node)
        return if node.is_a?(EXPRESSION::Group::Passive) && node.implicit?
        return if node.is_a?(EXPRESSION::Assertion::Base) ||
                  node.is_a?(EXPRESSION::Anchor::Base) ||
                  node.is_a?(EXPRESSION::Group::Comment)

        summary = summarize(node)
        if summary.hard || summary.body_nullable || !finite_disjoint?(summary.first, follow) ||
           adjacent_assertion?(node)
          @skipped << Skip.new(node, :possessive,
                               possessive_skip_reason(node, summary, follow))
          return
        end

        @candidates << Candidate.new(node, :possessive, summary.first, follow,
                                    POSSESSIVE_PROOF)
      end

      def possessive_skip_reason(node, summary, follow)
        if summary.hard
          'body contains an unsupported construct (backreference, assertion, ' \
          '\K, conditional, absence group, or unbounded/unsupported class)'
        elsif summary.body_nullable
          'body can match empty, so iteration boundaries are not statically distinct'
        elsif adjacent_assertion?(node)
          'an assertion/anchor is adjacent; the proof does not cover its re-evaluation'
        elsif follow.equal?(Charset::ANY)
          'follow set is unbounded (unsupported suffix construct)'
        else
          'first(body) and follow set overlap, so backtracking may resume earlier'
        end
      end

      # Possessivization changes where a lookahead/lookbehind/anchor is
      # evaluated at retried boundaries, which is not covered by the
      # character-set proof, so stay conservative.
      def adjacent_assertion?(node)
        siblings = node.parent ? node.parent.expressions : nil
        return false unless siblings.is_a?(Array)

        index = siblings.index(node)
        neighboring = []
        neighboring << siblings[index - 1] if index && index > 0
        if index
          ((index + 1)...siblings.length).each do |i|
            neighboring << siblings[i]
            break unless summarize(siblings[i]).nullable
          end
        end

        neighboring.any? do |exp|
          exp.is_a?(EXPRESSION::Assertion::Base) ||
            exp.is_a?(EXPRESSION::Anchor::Base) ||
            exp.is_a?(EXPRESSION::Keep)
        end
      end

      def collect_atomic(node)
        candidate = atomic_candidate(node) if !node.quantified?
        @candidates << candidate if candidate
        return unless container?(node)
        node.each { |child| collect_atomic(child) }
      end

      def atomic_candidate(node)
        return nil unless node.is_a?(EXPRESSION::Group::Passive) && !node.implicit?
        return nil if inside_assertion?(node)

        summary = summarize(node)
        follow = @follows[node]
        return nil if summary.hard || summary.body_nullable
        return nil unless finite_disjoint?(summary.first, follow)
        return nil unless backtrack_stable?(node)

        Candidate.new(node, :atomic, summary.first, follow, ATOMIC_PROOF)
      end

      # The group body must not contain internal backtracking that could
      # change captures once the group is exited:
      #   * alternation alternatives have pairwise disjoint first sets
      #     (rules out same-position branch switches like (a|ab));
      #   * no reluctant quantifiers (they backtrack by construction);
      #   * every greedy quantifier is independently possessivizable given
      #     its global follow set.
      def backtrack_stable?(node)
        return false if inside_assertion?(node)
        if node.is_a?(EXPRESSION::Alternation)
          sets = node.expressions.map { |alt| summarize(alt) }
          return false if sets.any?(&:hard)
          # An alternative that can match empty leaves the engine free to
          # backtrack into it after the group exits; atomicity would change
          # that. Also rules out a nullable alternative that still has a
          # first character (c?).
          return false if sets.any?(&:nullable)
          return false unless pairwise_disjoint?(sets.map(&:first))
        elsif node.is_a?(EXPRESSION::Group::Atomic)
          return true # backtracking is already discarded inside
        elsif node.is_a?(EXPRESSION::Group::Absence) ||
              node.is_a?(EXPRESSION::Assertion::Base) ||
              node.is_a?(EXPRESSION::Conditional::Expression) ||
              node.is_a?(EXPRESSION::Keep)
          return false
        end

        if node.quantified?
          return false if node.quantifier.reluctant?
          return false if node.quantifier.greedy? && !possessive_candidate?(node)
        end

        return true unless container?(node)
        node.expressions.all? { |child| backtrack_stable?(child) }
      end

      def possessive_candidate?(node)
        @candidates.any? { |candidate| candidate.node.equal?(node) &&
                                      candidate.kind == :possessive }
      end

      def inside_assertion?(node)
        ancestor = node.parent
        while ancestor
          return true if ancestor.is_a?(EXPRESSION::Assertion::Base) ||
                         ancestor.is_a?(EXPRESSION::Group::Absence)
          ancestor = ancestor.respond_to?(:parent) ? ancestor.parent : nil
        end
        false
      end

      # ----- helpers -------------------------------------------------------------

      def finite_disjoint?(first, follow)
        return false if first.equal?(Charset::ANY) || follow.equal?(Charset::ANY)
        !Charset.intersect?(first, follow)
      end

      def pairwise_disjoint?(sets)
        sets.each_with_index do |left, index|
          sets[(index + 1)..].to_a.each do |right|
            return false if left.equal?(Charset::ANY) || right.equal?(Charset::ANY)
            return false if Charset.intersect?(left, right)
          end
        end
        true
      end

      def sequence_type?(node)
        SEQUENCE_TYPES.any? { |klass| node.is_a?(klass) }
      end

      def opaque?(node)
        node.is_a?(EXPRESSION::Group::Absence) ||
          node.is_a?(EXPRESSION::Assertion::Base) ||
          node.is_a?(EXPRESSION::Keep)
      end

      def container?(node)
        node.respond_to?(:each)
      end
    end
  end
end
