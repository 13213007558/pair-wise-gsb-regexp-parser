# frozen_string_literal: true

require_relative 'parser'

class Regexp
  # A conservative optimizer for Ruby regular expressions.
  #
  # It performs only two kinds of rewrite, and only when it can locally prove
  # that the rewrite cannot change whether the regex matches, the span of the
  # match, or any named/numbered capture:
  #
  # * making a greedy quantifier possessive (e.g. `a+b` -> `a++b`);
  # * making a subexpression atomic (e.g. `(?:ab)` -> `(?>ab)`, or
  #   `(ab)` -> `(?>(ab))`).
  #
  # Input and output are ordinary Ruby regex source strings; no alternative
  # matching engine is introduced. Everything that cannot be proven safe -
  # recursive subexpression calls, conditionals, \K, unsupported character
  # sets, case-insensitive matching, ... - is left untouched.
  class Optimizer
    Result = Struct.new(:original, :optimized, :changes, :skipped)

    # Location and proof for a single rewrite. `start`/`length` refer to the
    # original pattern source (quantifier location for possessive rewrites,
    # group location for atomic rewrites).
    Change = Struct.new(:kind, :start, :length, :before, :after,
                        :conditions, :exp)

    # First-set sentinels.
    UNKNOWN = :unknown # the expression may start with any character
    EMPTY   = :empty   # the continuation may succeed without consuming

    GREEDY_TO_POSSESSIVE = {
      :zero_or_one  => :zero_or_one_possessive,
      :zero_or_more => :zero_or_more_possessive,
      :one_or_more  => :one_or_more_possessive,
    }.freeze

    class << self
      def optimize(pattern, syntax: nil, options: nil)
        new.optimize(pattern, syntax: syntax, options: options)
      end
    end

    def optimize(pattern, syntax: nil, options: nil)
      source, input_options = extract_input(pattern, options)
      root = Regexp::Parser.parse(source, syntax, options: input_options)

      @changes = []
      @tree_root = root
      @alternative_parents = nil
      skipped = global_blocker(root)
      unless skipped
        scan_possessives(root)
        scan_atomics(root)
        apply_changes!
      end

      # When nothing changed, return the source verbatim. Re-serializing
      # could otherwise surface unrelated parser round-trip quirks of
      # chained quantifiers.
      Result.new(source,
                 @changes.empty? ? source : root.to_s,
                 @changes,
                 skipped || nil)
    end

    private

    def extract_input(pattern, options)
      case pattern
      when ::Regexp
        [pattern.source, pattern.options]
      when String
        [pattern, options]
      else
        raise ArgumentError,
              "Regexp or String expected, #{pattern.class} given"
      end
    end

    # ------------------------------------------------------------ global bail

    def global_blocker(root)
      return 'pattern is case-insensitive' if root.options[:i]

      root.each_expression(true) do |exp|
        case exp
        when Expression::Conditional::Expression,
             Expression::Conditional::Condition
          return 'contains a conditional expression ((?(...)...))'
        when Expression::Keep::Mark
          return 'contains a keep mark (\\K)'
        when Expression::Group::Options
          return 'contains an inline option group (e.g. (?i:...)/(?i))'
        when Expression::Group::Absence
          return 'contains an absence group ((?~...))'
        end

        if exp.is_a?(Expression::Backreference::Base) && subexpression_call?(exp)
          return 'contains a recursive subexpression call (\\g<...>)'
        end

        if exp.is_a?(Expression::Group::Passive) && exp.implicit?
          return 'contains a chained/nested quantifier; the implicit ' \
                   'grouping is kept unchanged'
        end
      end
      nil
    end

    def subexpression_call?(exp)
      %i[name_call number_call number_rel_call
         name_call_ab number_call_ab number_rel_call_ab
         name_call_sq number_call_sq number_rel_call_sq]
        .include?(exp.token)
    end

    # ----------------------------------------------------------- candidate scan

    def scan_possessives(container)
      container.expressions.each_with_index do |child, index|
        scan_possessives(child) if child.is_a?(Expression::Subexpression)
        check_possessive(child, container, index)
      end
    end

    def scan_atomics(container)
      container.expressions.each do |child|
        check_atomic(child)
        scan_atomics(child) if child.is_a?(Expression::Subexpression)
      end
    end

    # -------------------------------------------------- possessive rewrites

    def check_possessive(exp, container, index)
      return unless exp.quantified?
      quantifier = exp.quantifier
      return unless quantifier.greedy?
      return unless GREEDY_TO_POSSESSIVE.key?(quantifier.token)

      # A quantifier with min 0 can retreat all the way to zero repetitions;
      # possessive quantifiers never give those positions back, and this is
      # observable (e.g. `a*^` vs `a*+^`). Only min >= 1 is provably safe.
      return unless quantifier.min >= 1

      # If the quantified unit is itself inside an enclosing repetition,
      # possessivizing it can cut off the boundaries between repetitions of
      # that outer quantifier (e.g. `(b+){2}` matches "bbbb" via backtracking
      # inside, but `(b++){2}` does not match at all).
      return if inside_repetition?(container)

      first = quantified_first_set(exp)
      return if first.nil? || first == UNKNOWN

      rest = continuation_sets(container, index + 1)
      return if rest.nil?
      return if rest.include?(UNKNOWN)
      return unless disjoint?(first, rest)

      range_text = quantifier.max == -1 ? 'infinity' : quantifier.max
      after = possessive_text(quantifier)

      queue_change(
        kind: :possessive,
        exp: exp,
        start: quantifier.ts,
        length: quantifier.text.length,
        before: quantifier.text,
        after: after,
        conditions: [
          "#{quantifier.text.inspect} is greedy and repeats at least " \
          "once (1..#{range_text}); it therefore never needs to retreat " \
          'to a zero-repetition match',
          'the quantified unit is a fixed-length, non-empty, deterministic ' \
            'sequence: every repetition matches exactly one string and it ' \
            'contains no quantifier or alternative',
          'the first character the quantified unit can match is disjoint ' \
            'from every character the remainder of the pattern/branch can ' \
            'start with, so no backtracked repetition boundary can ever ' \
            'lead to a successful match',
        ],
      )
    end

    def possessive_text(quantifier)
      case quantifier.token
      when :zero_or_one  then '?+'
      when :zero_or_more then '*+'
      when :one_or_more  then '++'
      end
    end

    # True when the quantified expression sits inside a group whose own
    # quantifier could need to give up positions taken by the inner unit:
    #
    # * an outer quantifier with max > 1 may need to backtrack *inside* one
    #   iteration to find where the next iteration begins
    #   (`(b+){2}` matches, `(b++){2}` does not);
    # * an outer quantifier with min 0 may retreat from a full match to a
    #   skipped/empty one (`(?:(?:a+|z))?` can empty the capture,
    #   `(?:(?:a++|z))?` cannot).
    #
    # The check applies transitively through alternations and nested groups.
    def inside_repetition?(container)
      node = container
      while node
        if quantified_group_boundary?(node)
          q = node.quantifier
          return true if q.max != 1 || q.min.zero?
        end
        node = semantic_parent(node)
      end
      false
    end

    def quantified_group_boundary?(node)
      node.is_a?(Expression::Group::Base) && node.quantified?
    end

    # `Alternative#parent` is nil in the parse tree; its structural parent is
    # the enclosing Alternation, so we need an explicit map when climbing.
    def semantic_parent(node)
      node.parent || alternative_parents[node]
    end

    def alternative_parents
      @alternative_parents ||= begin
        index = {}
        index_alternatives(@tree_root, index)
        index
      end
    end

    def index_alternatives(node, index)
      return unless node.is_a?(Expression::Subexpression)
      if node.is_a?(Expression::Alternation)
        node.alternatives.each { |branch| index[branch] = node }
      end
      node.expressions.each { |child| index_alternatives(child, index) }
    end

    # First set of the unit the quantifier repeats. Returns nil when the unit
    # is not a deterministic fixed-length construct.
    def quantified_first_set(exp)
      case exp
      when Expression::CharacterSet
        set_first_set(exp)
      when Expression::Group::Atomic,
           Expression::Assertion::Base
        nil
      when Expression::Group::Passive
        exp.implicit? ? nil : deterministic_group_first(exp)
      when Expression::Group::Capture
        deterministic_group_first(exp)
      else
        exp.is_a?(Expression::Subexpression) ? nil : atom_first_set(exp)
      end
    end

    # A group body is deterministic iff it is a non-empty concatenation of
    # terminal fixed-length atoms without quantifiers or alternatives.
    def deterministic_group_first(group)
      children = group.expressions
      return nil if children.empty?
      return nil unless children.all? { |child| deterministic_atom?(child) }
      atom_first_set(children.first)
    end

    def deterministic_atom?(exp)
      return false if exp.quantified?
      if exp.is_a?(Expression::CharacterSet)
        set_first_set(exp) != UNKNOWN
      else
        exp.terminal? && atom_first_set(exp) != UNKNOWN
      end
    end

    # ----------------------------------------------------- atomic rewrites

    def check_atomic(exp)
      case exp
      when Expression::Group::Passive
        return if exp.implicit?
        return if exp.quantified? # quantified groups handled by possessive
        return if inside_repetition?(exp.parent)
        return unless deterministic_body?(exp)
        mode = :passive_to_atomic
      when Expression::Group::Capture
        return if exp.quantified? # quantified groups handled by possessive
        return if inside_repetition?(exp.parent)
        return unless deterministic_body?(exp)
        mode = :wrap_capture
      else
        return
      end
      conditions = [
        'the group body is a non-empty, fixed-length concatenation with no ' \
          'quantifiers or alternatives, so it has at most one possible ' \
          'match at each starting position',
        'because the body match is unique, every backtracking position ' \
          'saved by the ordinary group fails exactly the same way when ' \
          're-entered; discarding them changes neither the match nor any ' \
          'capture',
      ]

      if mode == :passive_to_atomic
        before = exp.to_s
        queue_change(
          kind: :atomic_passive,
          exp: exp,
          start: exp.ts,
          length: exp.full_length,
          before: before,
          after: nil, # computed at apply time
          conditions: conditions,
        )
      else
        before = exp.to_s
        queue_change(
          kind: :atomic_capture,
          exp: exp,
          start: exp.ts,
          length: exp.full_length,
          before: before,
          after: nil,
          conditions: conditions,
        )
      end
    end

    def deterministic_body?(group)
      children = group.expressions
      return false if children.empty?
      children.all? { |child| deterministic_atom?(child) }
    end

    # --------------------------------------------------------- first sets

    # First set of a single, unquantified terminal atom: an Array of chars,
    # or UNKNOWN.
    def atom_first_set(exp)
      case exp
      when Expression::Literal
        exp.text.empty? ? UNKNOWN : [exp.text[0]]
      when Expression::CharacterSet
        set_first_set(exp)
      when Expression::EscapeSequence::Base
        escape_first_set(exp)
      else
        UNKNOWN
      end
    end

    ESCAPE_CLASSES = [
      Expression::EscapeSequence::Literal,
      Expression::EscapeSequence::AsciiEscape,
      Expression::EscapeSequence::Backspace,
      Expression::EscapeSequence::Bell,
      Expression::EscapeSequence::FormFeed,
      Expression::EscapeSequence::Newline,
      Expression::EscapeSequence::Return,
      Expression::EscapeSequence::Tab,
      Expression::EscapeSequence::VerticalTab,
      Expression::EscapeSequence::Octal,
      Expression::EscapeSequence::Hex,
      Expression::EscapeSequence::Codepoint,
      Expression::EscapeSequence::UTF8Hex,
      Expression::EscapeSequence::Control,
      Expression::EscapeSequence::Meta,
      Expression::EscapeSequence::MetaControl,
    ].freeze

    def escape_first_set(exp)
      return UNKNOWN unless ESCAPE_CLASSES.any? { |klass| exp.is_a?(klass) }
      [exp.char]
    rescue StandardError
      UNKNOWN
    end

    # Only plain positive sets made of literals/ranges are analyzed.
    # Negated sets, POSIX classes, properties, type escapes (\d, \w),
    # intersections and codepoint lists are unsupported and bail out.
    def set_first_set(exp)
      return UNKNOWN if exp.negative?

      chars = []
      exp.expressions.each do |member|
        case member
        when Expression::CharacterSet::Range
          from = set_member_char(member.expressions.first)
          to   = set_member_char(member.expressions.last)
          return UNKNOWN if from.nil? || to.nil?
          return UNKNOWN if from.ord > to.ord
          (from.ord..to.ord).each { |ord| chars << ord.chr(from.encoding) }
        when Expression::Literal
          return UNKNOWN if member.text.empty?
          chars << member.text[0]
        when Expression::EscapeSequence::Literal
          char = set_member_char(member)
          return UNKNOWN if char.nil?
          chars << char
        else
          return UNKNOWN
        end
      end
      chars.empty? ? UNKNOWN : chars.uniq
    end

    def set_member_char(exp)
      return exp.text[0] if exp.is_a?(Expression::Literal) && !exp.text.empty?
      set = escape_first_set(exp)
      set.is_a?(Array) && set.length == 1 ? set.first : nil
    end

    # First set of the continuation of element `index - 1` in `container`,
    # taking nullable prefixes into account and walking up through enclosing
    # groups. Returns an Array of single-char Arrays/sentinels:
    #   containing UNKNOWN - an unanalyzable atom may begin the continuation
    #   [EMPTY]             - the continuation can be empty (end of pattern)
    # Returns nil when the tree structure cannot be crossed safely.
    def continuation_sets(container, index)
      sets, nullable = suffix_first(container, index, [])
      return nil if sets.nil?
      sets << EMPTY if nullable
      sets.uniq
    end

    # Returns [sets, nullable] for the suffix of `container` beginning at
    # `index`. The sets are the characters that can begin the suffix; when
    # every element up to the end is nullable, the scan continues after the
    # enclosing construct and `nullable` may come back true.
    def suffix_first(container, index, seen)
      sets = []
      children = container.expressions
      (index...children.length).each do |i|
        first, nullable = element_first(children[i], seen)
        return [nil, false] if first.nil?
        sets.concat(first)
        return [sets.uniq, false] unless nullable
      end
      continuation_after_container(container, sets, seen)
    end

    # First set / nullability of one sequence element. Returns nil sets for
    # unsupported constructs.
    def element_first(exp, seen)
      case exp
      when Expression::Anchor::Base
        [[], true]
      when Expression::Alternation
        alternation_first(exp, seen)
      when Expression::Group::Passive
        return [nil, false] if exp.implicit?
        group_first(exp, seen)
      when Expression::Group::Capture, Expression::Group::Atomic
        group_first(exp, seen)
      when Expression::Assertion::Base, Expression::Conditional::Expression,
           Expression::Group::Options, Expression::Group::Comment,
           Expression::Group::Absence
        [nil, false]
      else
        terminal_first(exp)
      end
    end

    def terminal_first(exp, _seen = nil)
      set = if exp.is_a?(Expression::CharacterSet)
              set_first_set(exp)
            else
              atom_first_set(exp)
            end
      return [nil, false] if set == UNKNOWN
      [set, exp.quantified? && exp.quantifier.min.zero?]
    end

    def group_first(group, seen)
      return [nil, false] if seen.include?(group.object_id)
      inner_seen = seen + [group.object_id]
      inner_sets, inner_nullable = suffix_first(group, 0, inner_seen)
      return [nil, false] if inner_sets.nil?

      if group.quantified?
        # The group always offers its body's first set (a repetition starts
        # by matching the body).
        return [inner_sets, false] unless group.quantifier.min.zero?

        # min 0: the group may be skipped, so the continuation after it is
        # also a possible start.
        after_sets, after_nullable =
          continuation_after_container(group, [], inner_seen)
        return [nil, false] if after_sets.nil?
        [inner_sets.concat(after_sets).uniq, inner_nullable || after_nullable]
      else
        [inner_sets, inner_nullable]
      end
    end

    def alternation_first(alt, seen)
      sets = []
      nullable = false
      alt.alternatives.each do |sequence|
        branch_sets, branch_nullable = suffix_first(sequence, 0, seen)
        return [nil, false] if branch_sets.nil?
        sets.concat(branch_sets)
        nullable ||= branch_nullable
      end
      [sets.uniq, nullable]
    end

    # The entire body of `container` was nullable. Continue the scan after
    # the container in its parent, folding in the `accumulated` first sets.
    def continuation_after_container(container, accumulated, seen)
      # An Alternative has a nil `#parent`; reaching the end of a branch
      # also means reaching the end of its whole Alternation, so climb past
      # the alternation to whatever follows it.
      node = container
      while node
        parent = semantic_parent(node)
        return [accumulated.uniq, true] if parent.nil?

        case parent
        when Expression::Alternation
          node = parent
        when Expression::Root,
             Expression::Group::Atomic,
             Expression::Group::Passive,
             Expression::Group::Capture
          index = parent.expressions.index(node)
          return [nil, false] if index.nil?
          after_sets, nullable = suffix_first(parent, index + 1, seen)
          return [nil, false] if after_sets.nil?
          return [accumulated.concat(after_sets).uniq, nullable]
        else
          return [nil, false]
        end
      end
      [accumulated.uniq, true]
    end

    def disjoint?(first, continuation)
      first_set = Array(first)
      continuation.each do |set|
        next if set == EMPTY
        return false unless (Array(set) & first_set).empty?
      end
      true
    end

    # ------------------------------------------------------------- apply

    def queue_change(attrs)
      @changes << Change.new(
        attrs[:kind], attrs[:start], attrs[:length],
        attrs[:before], attrs[:after], attrs[:conditions], attrs[:exp]
      )
    end

    def apply_changes!
      # Apply possessive rewrites first (they touch the quantifier), then
      # atomic wrappings (they touch the group structure). Multiple safe
      # rewrites compose because each one only removes backtracking paths
      # that its proof showed could never succeed.
      @changes.each do |change|
        case change.kind
        when :possessive      then apply_possessive(change)
        when :atomic_passive  then apply_atomic_passive(change)
        when :atomic_capture  then apply_atomic_capture(change)
        end
      end
    end

    def apply_possessive(change)
      exp = change[:exp]
      quantifier = exp.quantifier
      token_name = GREEDY_TO_POSSESSIVE.fetch(quantifier.token)
      exp.quantifier = Expression::Quantifier.construct(
        token: token_name,
        text:  change.after,
        ts:    quantifier.ts,
      )
    end

    def apply_atomic_passive(change)
      group = change[:exp]
      # Group#parts emits `opening_text + children + ')'`, so replacing the
      # opening `(?:` with `(?>` turns the passive group into an atomic one
      # while preserving body and quantifier verbatim.
      group.text = '(?>' + group.text['(?:'.length..].to_s
      change.after = group.to_s
    end

    def apply_atomic_capture(change)
      group = change[:exp]
      # Wrap structurally: insert an Atomic between the parent and the
      # capturing group, keeping the capture (and its number/name) intact.
      parent = group.parent
      index = parent.expressions.index(group)
      return if index.nil?

      atomic = Expression::Group::Atomic.construct(
        token: :atomic,
        ts:    group.ts,
        level: group.level,
        set_level: group.set_level,
        conditional_level: group.conditional_level,
        options: group.options,
      )
      atomic.text = '(?>'
      parent.expressions[index] = atomic
      atomic << group
      if group.quantified?
        # The quantifier belongs to the whole wrapped group, not the inner
        # capture.
        atomic.quantifier = group.quantifier
        group.quantifier = nil
      end
      change.after = group_with_quantifier(atomic)
    end

    def group_with_quantifier(group)
      body = group.expressions.map { |child| child.to_s(:original) }.join
      text = '(?>' + body + ')'
      text << group.quantifier.to_s if group.quantified?
      text
    end

  end
end
