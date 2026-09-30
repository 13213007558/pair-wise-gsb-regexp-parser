# frozen_string_literal: true

# A restricted, backtracking regular expression matcher that runs directly
# on the Regexp::Parser AST.
#
# Unlike Ruby's MatchData, which only keeps the *last* span of a repeated
# capture group, this matcher additionally records every enter/exit span of
# every capture group along the single successful path that produced the
# overall match.
#
# Supported syntax (anything else is rejected *before* matching):
#
# - literals, e.g. `a`, `abc`
# - character sets, e.g. `[abc]`, `[^a-z]` (members may only be literals
#   and ranges)
# - concatenation and alternation (`|`)
# - greedy and reluctant quantifiers: `*`, `+`, `?`, `{m,n}` and their
#   reluctant `?` variants, including Ruby's reluctant intervals `{m,n}?`
#   (possessive quantifiers are rejected)
# - anchors: `^`, `$`, `\A`, `\z`, `\Z`, `\b`, `\B`, `\G`
# - plain capture groups `(...)` (named groups behave identically) and
#   non-capturing groups `(?:...)`
#
# Semantics:
#
# - left-to-right search: the leftmost starting position that yields a
#   match wins, just like Regexp#match
# - greedy quantifiers prefer more iterations, reluctant ones fewer;
#   alternatives are tried left to right
# - captures made on branches that are later abandoned through
#   backtracking are rolled back and never appear in the result
# - ALL reported positions are *character* offsets (not byte offsets),
#   consistent with MatchData#begin/#end; end offsets are exclusive
# - word boundaries (\b, \B) use the ASCII definition of word
#   characters: [A-Za-z0-9_]
# - patterns with the case-insensitive option /i are rejected
class Regexp::Matcher
  # base class for all matcher-specific errors
  class Error < Regexp::Parser::Error; end

  # raised when the pattern contains expressions outside the supported subset
  class UnsupportedError < Error; end

  E = Regexp::Expression

  SUPPORTED_CLASSES = [
    E::Root,
    E::Literal,
    E::CharacterSet,
    E::CharacterSet::Range,
    E::Sequence,       # also covers Alternative
    E::Alternation,
    E::Group::Capture, # also covers Group::Named
    E::Group::Passive,
    E::Anchor::BeginningOfLine,
    E::Anchor::EndOfLine,
    E::Anchor::BeginningOfString,
    E::Anchor::EndOfString,
    E::Anchor::EndOfStringOrBeforeEndOfLine,
    E::Anchor::WordBoundary,
    E::Anchor::NonWordBoundary,
    E::Anchor::MatchStart,
  ].freeze

  WORD_CHAR = /[A-Za-z0-9_]/.freeze

  # Convenience shorthand for Regexp::Matcher.new(pattern).match(string, pos).
  def self.match(pattern, string, pos = 0)
    new(pattern).match(string, pos)
  end

  attr_reader :root, :group_count

  def initialize(pattern)
    @root =
      case pattern
      when E::Root then pattern
      when Regexp  then Regexp::Parser.parse(pattern)
      else Regexp::Parser.parse(pattern.to_s)
      end
    validate!
    @group_count = 0
    @root.each_expression do |exp|
      if exp.is_a?(E::Group::Capture) && exp.number > @group_count
        @group_count = exp.number
      end
    end
  end

  # Searches +string+ from character offset +pos+ left to right and returns
  # a Regexp::Matcher::Match, or nil if the pattern matches nowhere.
  def match(string, pos = 0)
    chars = string.to_s.chars
    pos += chars.length if pos < 0
    return nil if pos < 0 || pos > chars.length

    engine = Engine.new(chars, pos)
    result = engine.search(root, pos)
    result && Match.new(string.to_s, result[0], result[1], engine.state, group_count)
  end

  private

  def validate!
    root.each_expression(true) do |exp|
      unless SUPPORTED_CLASSES.any? { |klass| exp.is_a?(klass) }
        raise UnsupportedError,
              "unsupported expression: #{exp.class} (#{exp.token.inspect} #{exp.text.inspect})"
      end
      if exp.quantified? && exp.quantifier.possessive?
        raise UnsupportedError, "possessive quantifiers are not supported: #{exp}"
      end
      if exp.options && exp.options[:i]
        raise UnsupportedError, 'the case-insensitive option /i is not supported'
      end
    end
  end

  # Records the enter/exit spans of capture groups. Mutations are rolled
  # back via checkpoints whenever a branch is abandoned, so spans from
  # failed paths never leak into the final result.
  class CaptureState
    def initialize
      @histories = Hash.new { |hash, key| hash[key] = [] }
      @open = {}
    end

    def enter(number, pos)
      @open[number] = pos
    end

    def exit(number, pos)
      @histories[number] << [@open[number], pos]
    end

    def checkpoint
      lengths = {}
      @histories.each { |number, spans| lengths[number] = spans.length }
      [lengths, @open.dup]
    end

    def restore(checkpoint)
      lengths, open = checkpoint
      @histories.each do |number, spans|
        keep = lengths[number] || 0
        spans.slice!(keep..-1) if spans.length > keep
      end
      @open = open.dup
    end

    def [](number)
      @histories[number]
    end
  end

  # The backtracking engine. Continuation-passing style: every matcher
  # calls its continuation with the new position on success and returns
  # nil to trigger backtracking. Choice points (search start positions,
  # alternatives, quantifier iterations) snapshot the capture state and
  # restore it when a branch fails.
  class Engine
    attr_reader :state

    def initialize(chars, search_start)
      @chars = chars
      @length = chars.length
      @search_start = search_start
      @state = CaptureState.new
    end

    def search(root, from)
      (from..@length).each do |start|
        checkpoint = @state.checkpoint
        result = match_children(root, start) { |stop| [start, stop] }
        return result if result

        @state.restore(checkpoint)
      end
      nil
    end

    private

    def match_children(exp, pos, &cont)
      match_list(exp.expressions, pos, &cont)
    end

    def match_list(exps, pos, &cont)
      if exps.empty?
        cont.call(pos)
      else
        head = exps.first
        tail = exps.drop(1)
        match_expression(head, pos) { |next_pos| match_list(tail, next_pos, &cont) }
      end
    end

    def match_expression(exp, pos, &cont)
      if (inner = reluctant_interval_group(exp))
        # The parser reads `x{m,n}?` as chained quantifiers (an implicit
        # passive group `(?:x{m,n})?`), but Ruby treats it as a reluctant
        # interval quantifier. Reinterpret it here to match Ruby.
        quantifier = inner.quantifier
        match_repeated(inner, quantifier.min, quantifier.max, :reluctant, pos, 0, &cont)
      elsif exp.quantified?
        quantifier = exp.quantifier
        match_repeated(exp, quantifier.min, quantifier.max, quantifier.mode, pos, 0, &cont)
      else
        match_base(exp, pos, &cont)
      end
    end

    # Detects the parser's representation of `x{m,n}?`: an implicit passive
    # group with a greedy `?` quantifier wrapping a single expression with an
    # interval quantifier. Returns the inner expression, or nil.
    def reluctant_interval_group(exp)
      return nil unless exp.is_a?(E::Group::Passive) && exp.implicit?
      return nil unless exp.quantified? && exp.quantifier.text == '?'
      return nil unless exp.expressions.length == 1

      inner = exp.expressions.first
      inner.quantified? && inner.quantifier.token == :interval ? inner : nil
    end

    def match_base(exp, pos, &cont)
      case exp
      when E::Literal
        chars = exp.text.chars
        @chars[pos, chars.length] == chars ? cont.call(pos + chars.length) : nil
      when E::CharacterSet
        char = @chars[pos]
        char && set_matches?(exp, char) ? cont.call(pos + 1) : nil
      when E::Alternation
        match_alternation(exp, pos, &cont)
      when E::Group::Capture
        match_capture(exp, pos, &cont)
      when E::Anchor::Base
        anchor_matches?(exp, pos) ? cont.call(pos) : nil
      else # Root, Sequence, Alternative, Group::Passive
        match_children(exp, pos, &cont)
      end
    end

    def match_alternation(exp, pos, &cont)
      exp.alternatives.each do |alternative|
        checkpoint = @state.checkpoint
        result = match_children(alternative, pos, &cont)
        return result if result

        @state.restore(checkpoint)
      end
      nil
    end

    def match_capture(exp, pos, &cont)
      number = exp.number
      @state.enter(number, pos)
      match_children(exp, pos) do |stop|
        @state.exit(number, stop)
        cont.call(stop)
      end
    end

    def match_repeated(exp, min, max, mode, pos, count, &cont)
      can_grow = max < 0 || count < max
      must_grow = count < min

      if mode == :reluctant
        unless must_grow
          checkpoint = @state.checkpoint
          result = cont.call(pos)
          return result if result

          @state.restore(checkpoint)
        end
        can_grow ? match_iteration(exp, min, max, mode, pos, count, &cont) : nil
      else # greedy
        if can_grow
          checkpoint = @state.checkpoint
          result = match_iteration(exp, min, max, mode, pos, count, &cont)
          return result if result

          @state.restore(checkpoint)
        end
        must_grow ? nil : cont.call(pos)
      end
    end

    def match_iteration(exp, min, max, mode, pos, count, &cont)
      match_base(exp, pos) do |grown|
        if grown == pos && count + 1 >= min
          # An iteration matched the empty string; repeating it would loop
          # forever, so (like Ruby) stop growing and continue.
          cont.call(grown)
        else
          match_repeated(exp, min, max, mode, grown, count + 1, &cont)
        end
      end
    end

    def set_matches?(set, char)
      matched = set.expressions.any? { |member| set_member_matches?(member, char) }
      set.negative? ? !matched : matched
    end

    def set_member_matches?(member, char)
      case member
      when E::CharacterSet::Range
        low, high = member.expressions.map(&:text)
        low <= char && char <= high
      else # E::Literal
        member.text == char
      end
    end

    def anchor_matches?(exp, pos)
      case exp
      when E::Anchor::BeginningOfString
        pos.zero?
      when E::Anchor::EndOfString
        pos == @length
      when E::Anchor::EndOfStringOrBeforeEndOfLine
        pos == @length || (pos == @length - 1 && @chars[pos] == "\n")
      when E::Anchor::BeginningOfLine
        pos.zero? || @chars[pos - 1] == "\n"
      when E::Anchor::EndOfLine
        pos == @length || @chars[pos] == "\n"
      when E::Anchor::WordBoundary
        word_boundary?(pos)
      when E::Anchor::NonWordBoundary
        !word_boundary?(pos)
      when E::Anchor::MatchStart
        pos == @search_start
      end
    end

    def word_boundary?(pos)
      before = pos > 0 && @chars[pos - 1] =~ WORD_CHAR
      after = pos < @length && @chars[pos] =~ WORD_CHAR
      !before != !after
    end
  end

  # The result of a successful match.
  #
  # All positions are character offsets into the original string; end
  # offsets are exclusive. Spans are returned as exclusive Ranges
  # (start...stop).
  class Match
    attr_reader :string, :range, :group_count

    def initialize(string, start, stop, state, group_count)
      @string = string
      @range = start...stop
      @group_count = group_count
      @histories = {}
      (1..group_count).each do |number|
        @histories[number] = state[number].map { |from, to| from...to }.freeze
      end
      @histories.freeze
    end

    # The whole matched substring.
    def matched
      string[range]
    end
    alias to_s matched

    # The final span of capture group +number+, or nil if the group did
    # not participate on the successful path. This mirrors MatchData:
    # for repeated groups it is the span of the last iteration.
    def capture_range(number)
      histories.fetch(number).last
    end

    # The final captured substring of group +number+, or nil.
    def capture(number)
      span = capture_range(number)
      span && string[span]
    end

    # Final captured substrings of all groups, like MatchData#captures.
    def captures
      (1..group_count).map { |number| capture(number) }
    end

    # Every enter/exit span of group +number+ on the successful path, in
    # order, as exclusive Ranges of character offsets. Unlike MatchData,
    # repeated groups report all of their iterations here.
    def history(number)
      histories.fetch(number)
    end

    def [](number)
      number.zero? ? matched : capture(number)
    end

    def to_a
      [matched, *captures]
    end

    private

    attr_reader :histories
  end
end
