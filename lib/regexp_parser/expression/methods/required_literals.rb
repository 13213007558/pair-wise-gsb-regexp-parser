# frozen_string_literal: true

module Regexp::Expression
  class Base
    # Returns a Regexp::Prefilter::Condition that is guaranteed to hold for
    # every string this expression matches. Expressions that can not make
    # any guarantees (unknown or zero-width constructs, backreferences, ...)
    # contribute a tautology. See Regexp::Prefilter.derive.
    def required_literal_condition
      return Regexp::Prefilter::Condition.tautology if optional?

      required_literal_condition_inner
    end

    private

    def required_literal_condition_inner
      Regexp::Prefilter::Condition.tautology
    end
  end

  class Literal
    private

    def required_literal_condition_inner
      Regexp::Prefilter::Condition.literal(
        text, case_insensitive: case_insensitive?, ts: ts, te: te
      )
    end
  end

  class Subexpression
    private

    def required_literal_condition_inner
      Regexp::Prefilter::Condition.all(
        expressions.map(&:required_literal_condition)
      )
    end
  end

  class Alternation
    private

    def required_literal_condition_inner
      Regexp::Prefilter::Condition.any(
        alternatives.map(&:required_literal_condition)
      )
    end
  end

  class CharacterSet
    private

    # Only a positive set matching exactly one literal char (e.g. [a])
    # yields a required literal; anything else is too ambiguous.
    def required_literal_condition_inner
      member = self[0]
      if !negative? && length == 1 && member.instance_of?(Literal)
        Regexp::Prefilter::Condition.literal(
          member.text, case_insensitive: case_insensitive?, ts: ts, te: te
        )
      else
        Regexp::Prefilter::Condition.tautology
      end
    end
  end

  class Conditional::Expression
    private

    # With only one branch, the implicit empty else-branch can match, so no
    # literal is guaranteed. The condition itself contributes nothing.
    def required_literal_condition_inner
      if branches.length < 2
        Regexp::Prefilter::Condition.tautology
      else
        Regexp::Prefilter::Condition.any(
          branches.map(&:required_literal_condition)
        )
      end
    end
  end

  # Concrete single-character escapes (\n, \x41, \u0041, \cA, ...)
  # each require their decoded character to occur.
  EscapeSequence::Base.class_eval do
    private

    def required_literal_condition_inner
      Regexp::Prefilter::Condition.literal(
        char, case_insensitive: case_insensitive?, ts: ts, te: te
      )
    end
  end

  EscapeSequence::CodepointList.class_eval do
    private

    def required_literal_condition_inner
      Regexp::Prefilter::Condition.literal(
        chars.join, case_insensitive: case_insensitive?, ts: ts, te: te
      )
    end
  end

  [
    # The contents of negative lookarounds must *not* occur, so they can
    # not contribute required literals.
    Assertion::NegativeLookahead,
    Assertion::NegativeLookbehind,
    # What a backreference or subexpression call matches depends on the
    # referenced group actually participating, which can not be guaranteed
    # in general, so they contribute nothing.
    Backreference::Base,
    # Absence groups (?~...) exclude rather than require content.
    Group::Absence,
  ].each do |klass|
    klass.class_eval do
      private

      def required_literal_condition_inner
        Regexp::Prefilter::Condition.tautology
      end
    end
  end

  # Positive lookarounds do require their contents to occur in the
  # haystack, but they are zero-width, so their literals overlap with the
  # surrounding sequence and must not merge into adjacent ones.
  [Assertion::Lookahead, Assertion::Lookbehind].each do |klass|
    klass.class_eval do
      private

      def required_literal_condition_inner
        condition = Regexp::Prefilter::Condition.all(
          expressions.map(&:required_literal_condition)
        )
        if condition.is_a?(Regexp::Prefilter::Literal)
          Regexp::Prefilter::All.new([condition])
        else
          condition
        end
      end
    end
  end
end
