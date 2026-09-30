# frozen_string_literal: true

class Regexp
  # Regexp::Matcher is a restricted, AST-based backtracking matcher.
  #
  # Unlike Ruby's MatchData, which only keeps the *last* value of a capture
  # group that was entered repeatedly, this matcher records the full history
  # of every capture group along the successful match path: each time a
  # capture group is entered and exited, the span is appended to that group's
  # history. Captures made on branches that are later abandoned during
  # backtracking are rolled back and never appear in the result.
  #
  # Supported syntax (everything else is rejected up front, before any
  # matching is attempted, by raising Regexp::Matcher::UnsupportedError):
  #
  # - literals (e.g. +abc+)
  # - character sets, including ranges and negation (e.g. +[a-c]+, +[^x]+);
  #   set members must be literals or literal ranges
  # - concatenation and alternation (e.g. +ab+, +a|bc+)
  # - greedy and reluctant (lazy) quantifiers (+*+, +++, +?+, +{m,n}+ and
  #   their lazy variants); possessive quantifiers are not supported
  # - anchors: +^+, +$+, +\\A+, +\\z+, +\\Z+
  # - plain capture groups +(...)+ (named groups are treated as ordinary
  #   numbered groups) and non-capturing groups +(?:...)+
  #
  # Not supported: assertions/lookarounds, backreferences, atomic and
  # absence groups, conditionals, comments, option switches, free-spacing
  # nodes, escape sequences, character types (such as +\\d+ or +.+), posix
  # classes, unicode properties, set intersections, word-boundary anchors,
  # and case-insensitive matching.
  #
  # Repetition follows Ruby's rules: greedy quantifiers consume as much as
  # possible before backtracking, reluctant quantifiers as little as
  # possible, and an iteration that matches the empty string terminates the
  # repetition (its captures are kept, as Ruby does).
  #
  # Note: the parser represents chained quantifiers such as +a{2,}?+ as an
  # implicit passive group (+(?:a{2,})?+), so the laziness of interval
  # quantifiers is matched as parsed, not as Ruby would match the source.
  #
  # Known difference: Ruby's engine (Onigmo) propagates an "empty status"
  # between nested repetitions, so when certain quantified capture groups
  # match the empty string, enclosing repetitions stop iterating early
  # (e.g. /((a|b)(y+|){1,2})+/ matches only "a" on "ab"). That behavior
  # emerges from Onigmo's compile-time transformations and is not replicated
  # here; this matcher only applies the direct empty-iteration rule and may
  # return a longer overall match for such patterns.
  #
  # All offsets returned by this matcher are *character* offsets (not byte
  # offsets), counted from the start of the searched string.
  #
  # Example:
  #
  #   matcher = Regexp::Matcher.new('(a(b)?)+')
  #   match = matcher.match('abab')
  #   match.to_a        # => ["abab", "ab", "b"]
  #   match.history(1)  # => [[0, 2], [2, 4]]
  #   match.history(2)  # => [[1, 2], [3, 4]]
  #
  class Matcher
    # Raised when a pattern uses syntax outside the supported subset.
    class UnsupportedError < Regexp::Parser::Error; end

    E = Regexp::Expression

    SUPPORTED_EXPRESSIONS = [
      E::Root,
      E::Literal,
      E::CharacterSet,
      E::CharacterSet::Range,
      E::Alternation,
      E::Alternative,
      E::Sequence,
      E::Group::Capture, # includes Group::Named
      E::Group::Passive,
      E::Anchor::BeginningOfLine,
      E::Anchor::EndOfLine,
      E::Anchor::BeginningOfString,
      E::Anchor::EndOfString,
      E::Anchor::EndOfStringOrBeforeEndOfLine,
    ].freeze

    SUPPORTED_SET_MEMBERS = [E::Literal, E::CharacterSet::Range].freeze

    # The root expression of the parsed pattern.
    attr_reader :root

    # Builds a matcher from a String, a Regexp, or an already parsed
    # Regexp::Expression::Root. The pattern is validated eagerly; anything
    # outside the supported subset raises UnsupportedError here, before any
    # matching takes place.
    def initialize(pattern)
      @root = pattern.is_a?(E::Root) ? pattern : Regexp::Parser.parse(pattern)
      validate!
    end

    # The number of capture groups in the pattern.
    def group_count
      @group_count ||= root.each_expression.count { |exp| exp.is_a?(E::Group::Capture) }
    end

    # Searches +string+ left to right, starting at character offset +offset+,
    # and returns a Regexp::Matcher::Match for the first successful match,
    # or nil if the pattern does not match anywhere.
    def match(string, offset = 0)
      string = String(string)
      chars = string.chars
      offset = Integer(offset)
      if offset.negative? || offset > chars.length
        raise IndexError, "offset #{offset} is out of bounds"
      end

      trail = []
      offset.upto(chars.length) do |start|
        trail.clear
        final = nil
        matched = match_node(root, start, chars, trail) { |pos| final = pos; true }
        return Match.new(string, chars, start, final, trail, group_count) if matched
      end
      nil
    end

    # The result of a successful match. Group spans are character offsets
    # into the searched string.
    class Match
      # The searched string.
      attr_reader :string

      def initialize(string, chars, start, final, trail, group_count)
        @string = string
        @chars = chars
        @start = start
        @final = final
        @histories = build_histories(trail, group_count)
      end

      # Character offset at which the whole match (group 0) or the given
      # capture group's final capture starts. nil if the group did not
      # participate in the match.
      def begin(group = 0)
        span(group)&.first
      end

      # Character offset at which the whole match (group 0) or the given
      # capture group's final capture ends. nil if the group did not
      # participate in the match.
      def end(group = 0)
        span(group)&.last
      end

      # The [begin, end] character span of the whole match (group 0) or of
      # the given capture group's final capture. nil if the group did not
      # participate in the match.
      def span(group = 0)
        group.zero? ? [@start, @final] : @histories[group]&.last
      end

      # The matched substring for the whole match (group 0) or for the given
      # capture group's final capture. nil if the group did not participate.
      def [](group)
        span = span(group)
        span && @chars[span[0]...span[1]].join
      end

      # The final captures of groups 1..n, like MatchData#captures.
      def captures
        (1...@histories.length).map { |i| self[i] }
      end

      # All [enter, exit] character spans recorded for the given capture
      # group along the successful match path, in chronological order.
      # Spans from branches that failed during backtracking are not included.
      def history(group)
        group.zero? ? [[@start, @final]] : @histories.fetch(group).dup
      end

      # A hash mapping each capture group number to its history of
      # [enter, exit] character spans (see #history).
      def histories
        result = {}
        @histories.each_with_index do |spans, i|
          result[i] = spans.dup unless i.zero?
        end
        result
      end

      # The matched substring of the whole match.
      def to_s
        self[0]
      end

      # The whole match followed by the final captures, like MatchData#to_a.
      def to_a
        [to_s, *captures]
      end

      def inspect
        format('#<%s %p %p>', self.class.name, to_s, captures)
      end

      private

      def build_histories(trail, group_count)
        histories = Array.new(group_count + 1) { [] }
        open = Hash.new { |hash, key| hash[key] = [] }
        trail.each do |event, number, pos|
          if event == :enter
            open[number] << pos
          else
            histories[number] << [open[number].pop, pos]
          end
        end
        histories.each(&:freeze).freeze
      end
    end

    private

    def validate!
      root.each_expression(true) do |exp|
        unless SUPPORTED_EXPRESSIONS.any? { |klass| exp.is_a?(klass) }
          raise UnsupportedError, "unsupported expression: #{exp.class} (#{exp})"
        end
        if exp.quantified? && exp.quantifier.possessive?
          raise UnsupportedError, "possessive quantifiers are not supported: #{exp}"
        end
        if exp.options[:i]
          raise UnsupportedError, "case-insensitive matching is not supported: #{exp}"
        end
        validate_set_members!(exp) if exp.is_a?(E::CharacterSet)
      end
      true
    end

    def validate_set_members!(set)
      set.expressions.each do |member|
        unless SUPPORTED_SET_MEMBERS.any? { |klass| member.is_a?(klass) }
          raise UnsupportedError,
                "unsupported character set member: #{member.class} (#{member})"
        end
      end
    end

    # Matching is implemented as a depth-first search with explicit
    # continuations. Every frame maintains the invariant that a failed call
    # leaves the capture trail unchanged, so once the search succeeds the
    # trail holds exactly the group entries/exits of the successful path.

    def match_node(exp, pos, chars, trail, &cont)
      if exp.quantified?
        match_quantified(exp, pos, chars, trail, &cont)
      else
        match_atom(exp, pos, chars, trail, &cont)
      end
    end

    def match_atom(exp, pos, chars, trail, &cont)
      case exp
      when E::Literal
        literal_match?(exp, pos, chars) && cont.call(pos + exp.text.length)
      when E::CharacterSet
        set_match?(exp, chars[pos]) && cont.call(pos + 1)
      when E::Anchor::Base
        anchor_match?(exp, pos, chars) && cont.call(pos)
      when E::Group::Capture
        match_capture(exp, pos, chars, trail, &cont)
      when E::Alternation
        exp.alternatives.any? do |alternative|
          match_sequence(alternative.expressions, 0, pos, chars, trail, &cont)
        end
      when E::Subexpression # Root, Sequence, Alternative, Group::Passive
        match_sequence(exp.expressions, 0, pos, chars, trail, &cont)
      else
        raise UnsupportedError, "unsupported expression: #{exp.class} (#{exp})"
      end
    end

    def match_sequence(exps, index, pos, chars, trail, &cont)
      return cont.call(pos) if index >= exps.length

      match_node(exps[index], pos, chars, trail) do |next_pos|
        match_sequence(exps, index + 1, next_pos, chars, trail, &cont)
      end
    end

    def match_capture(exp, pos, chars, trail, &cont)
      mark = trail.length
      trail << [:enter, exp.number, pos]
      matched = match_sequence(exp.expressions, 0, pos, chars, trail) do |end_pos|
        trail << [:exit, exp.number, end_pos]
        keep = cont.call(end_pos)
        trail.pop unless keep
        keep
      end
      trail.slice!(mark..-1) unless matched
      matched
    end

    def match_quantified(exp, pos, chars, trail, &cont)
      quantifier = exp.quantifier
      min = quantifier.min
      max = quantifier.max.negative? ? Float::INFINITY : quantifier.max
      if quantifier.reluctant?
        match_lazy(exp, 0, min, max, pos, chars, trail, &cont)
      else
        match_greedy(exp, 0, min, max, pos, chars, trail, &cont)
      end
    end

    def match_greedy(exp, count, min, max, pos, chars, trail, &cont)
      if count < max
        matched = match_atom(exp, pos, chars, trail) do |next_pos|
          if next_pos == pos && count >= min
            # An empty iteration terminates the repetition, keeping its
            # captures, as Ruby does (e.g. /(a?)*/ captures "" on "aaa").
            cont.call(next_pos)
          else
            match_greedy(exp, count + 1, min, max, next_pos, chars, trail, &cont)
          end
        end
        return true if matched
      end
      count >= min && cont.call(pos)
    end

    def match_lazy(exp, count, min, max, pos, chars, trail, &cont)
      return true if count >= min && cont.call(pos)
      return false if count >= max

      match_atom(exp, pos, chars, trail) do |next_pos|
        if next_pos == pos && count + 1 >= min
          cont.call(next_pos) # empty iteration terminates the repetition
        else
          match_lazy(exp, count + 1, min, max, next_pos, chars, trail, &cont)
        end
      end
    end

    def set_match?(set, char)
      return false if char.nil?

      hit = set.expressions.any? { |member| set_member_match?(member, char) }
      set.negative? ? !hit : hit
    end

    # A Literal's text may span several characters, as the parser merges
    # consecutive literal characters into a single expression.
    def literal_match?(literal, pos, chars)
      chars[pos, literal.text.length] == literal.text.chars
    end

    def set_member_match?(member, char)
      case member
      when E::Literal
        member.text == char
      when E::CharacterSet::Range
        first, last = member.expressions
        first.text <= char && char <= last.text
      end
    end

    def anchor_match?(anchor, pos, chars)
      case anchor
      when E::Anchor::BeginningOfString
        pos.zero?
      when E::Anchor::EndOfString
        pos == chars.length
      when E::Anchor::EndOfStringOrBeforeEndOfLine
        pos == chars.length || (pos == chars.length - 1 && chars[pos] == "\n")
      when E::Anchor::BeginningOfLine
        # like Ruby, ^ does not match at the very end of the string
        pos.zero? || (pos < chars.length && chars[pos - 1] == "\n")
      when E::Anchor::EndOfLine
        pos == chars.length || chars[pos] == "\n"
      else
        raise UnsupportedError, "unsupported anchor: #{anchor.class} (#{anchor})"
      end
    end
  end
end
