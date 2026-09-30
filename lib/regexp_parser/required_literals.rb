# frozen_string_literal: true

# Regexp::RequiredLiterals analyzes a regular expression and derives a
# condition over literal fragments that is guaranteed to hold for every
# string the expression can match. It is meant for cheap pre-filtering:
# when many expressions are tested against many inputs, any input that
# violates the derived condition can be rejected without running the full
# expression.
#
# The derivation is conservative and never produces false negatives. Any
# construct that cannot be analyzed (character sets, backreferences, ...)
# degrades to Any, a condition that passes every input. In particular,
# text that merely occurs in the regexp source is not necessarily required
# in the input: optional branches, negative assertions, and character
# classes contribute no requirements.
#
#   condition = Regexp::RequiredLiterals.analyze(/foo(bar|baz)\d+qux/)
#   condition.to_s # => '"foo" AND ("bar" OR "baz") AND "qux"'
#   condition.match?('xxfoobaryyqux') # => true
#   condition.match?('xxfooyyqux')    # => false
#
module Regexp::RequiredLiterals
  # Derives a literal condition for the given Regexp, String, or
  # Regexp::Expression. Accepts the same optional syntax and options
  # arguments as Regexp::Parser.parse when given a Regexp or String.
  #
  # Returns a Condition responding to #match?(string).
  def self.analyze(input, syntax = nil, options: nil)
    root =
      if input.is_a?(Regexp::Expression::Base)
        input
      else
        Regexp::Parser.parse(input, syntax, options: options)
      end

    begin
      Analyzer.new.condition_for(root)
    rescue StandardError
      # If derivation fails for any reason, fall back to passing everything
      # rather than risking false negatives.
      Any.instance
    end
  end

  # Abstract base of the condition tree returned by .analyze.
  class Condition
    def match?(string)
      raise NotImplementedError
    end

    def &(other)
      All.build([self, other])
    end

    def |(other)
      One.build([self, other])
    end

    def inspect
      "#<#{self.class.name} #{self}>"
    end
  end

  # Unconditional pass. Used when no literal requirement can be derived.
  class Any < Condition
    def self.instance
      @instance ||= new
    end

    def match?(_string)
      true
    end

    def &(other)
      other
    end

    def |(_other)
      self
    end

    def to_s
      'ANY'
    end

    def ==(other)
      other.is_a?(Any)
    end
    alias eql? ==

    def hash
      self.class.hash
    end
  end

  # Requires a literal fragment to occur in the input. Case-insensitive
  # fragments are matched with the same case-folding semantics as Ruby's
  # Regexp engine; case-sensitive fragments are compared byte-wise, so
  # inputs in any encoding are handled without false negatives.
  class Literal < Condition
    attr_reader :text

    # The prefix/suffix/exact flags describe how the fragment relates to
    # the consumption of the expression it was derived from. They only
    # guide fragment merging during analysis and default to the safe side.
    def initialize(text, case_insensitive: false, prefix: false, suffix: false, exact: false)
      @text = text.dup.freeze
      @case_insensitive = case_insensitive
      @prefix = prefix
      @suffix = suffix
      @exact = exact
      @bytes = @text.b.freeze
    end

    def case_insensitive?
      @case_insensitive
    end

    # Whether the expression's consumption always begins with the fragment.
    def prefix?
      @prefix
    end

    # Whether the expression's consumption always ends with the fragment.
    def suffix?
      @suffix
    end

    # Whether the expression's consumption always equals the fragment.
    def exact?
      @exact
    end

    def match?(string)
      if case_insensitive?
        matcher ? matcher.match?(string) : true
      else
        string.b.include?(@bytes)
      end
    rescue Encoding::CompatibilityError, Encoding::InvalidByteSequenceError, ArgumentError
      true # never produce false negatives on encoding mismatches
    end

    def to_s
      case_insensitive? ? "#{text.inspect}(i)" : text.inspect
    end

    def ==(other)
      other.is_a?(Literal) &&
        text == other.text &&
        case_insensitive? == other.case_insensitive?
    end
    alias eql? ==

    def hash
      [self.class, text, case_insensitive?].hash
    end

    private

    # A small /i regexp over the literal shares Ruby's own case-folding
    # semantics, which String#downcase does not (e.g. /\x{3C3}/i matches
    # both "\x{3A3}" and "\x{3C2}").
    def matcher
      return @matcher if defined?(@matcher)

      @matcher = build_matcher
    end

    def build_matcher
      ::Regexp.new(::Regexp.escape(text), ::Regexp::IGNORECASE)
    rescue StandardError
      begin
        # e.g. fragments with invalid UTF-8 bytes from a //n regexp
        ::Regexp.new(::Regexp.escape(text.b), ::Regexp::IGNORECASE | ::Regexp::NOENCODING)
      rescue StandardError
        nil
      end
    end
  end

  # Requires all of its conditions to hold.
  class All < Condition
    attr_reader :conditions

    def self.build(conditions)
      flat = conditions.flat_map { |c| c.is_a?(All) ? c.conditions : [c] }
                       .reject { |c| c.is_a?(Any) }
                       .uniq
      return Any.instance if flat.empty?
      return flat.first if flat.length == 1

      new(flat)
    end

    def initialize(conditions)
      @conditions = conditions.freeze
    end

    def match?(string)
      conditions.all? { |c| c.match?(string) }
    end

    def to_s
      conditions.map { |c| c.is_a?(One) ? "(#{c})" : c.to_s }.join(' AND ')
    end

    def ==(other)
      other.is_a?(All) && conditions == other.conditions
    end
    alias eql? ==

    def hash
      [self.class, conditions].hash
    end
  end

  # Requires at least one of its conditions to hold.
  class One < Condition
    attr_reader :conditions

    def self.build(conditions)
      flat = conditions.flat_map { |c| c.is_a?(One) ? c.conditions : [c] }.uniq
      return Any.instance if flat.any? { |c| c.is_a?(Any) }
      return flat.first if flat.length == 1

      factor_common_prefix(flat) || new(flat)
    end

    # Strengthens a disjunction of plain literals by extracting their
    # longest common prefix, e.g. ("cat" OR "car") => "ca" AND ("t" OR "r").
    def self.factor_common_prefix(conditions)
      return unless conditions.length > 1
      return unless conditions.all? { |c| c.is_a?(Literal) }

      flags = conditions.map(&:case_insensitive?).uniq
      return unless flags.length == 1

      ci = flags.first
      prefix = longest_common_prefix(conditions.map(&:text))
      return if prefix.empty?

      # The common prefix is not a guaranteed suffix of the consumption:
      # /foo|foobar/ may consume "foobar", so "foo" is not mergeable to the
      # right, and repeating it is not contiguous.
      head = Literal.new(prefix, case_insensitive: ci, prefix: true)
      suffixes = conditions.map do |c|
        Literal.new(c.text[prefix.length..-1], case_insensitive: ci)
      end
      return head if suffixes.any? { |s| s.text.empty? }

      All.build([head, build(suffixes)])
    end

    def self.longest_common_prefix(strings)
      shortest = strings.min_by(&:length)
      shortest.length.times do |i|
        char = shortest[i]
        return shortest[0...i] unless strings.all? { |s| s[i] == char }
      end
      shortest
    end

    def initialize(conditions)
      @conditions = conditions.freeze
    end

    def match?(string)
      conditions.any? { |c| c.match?(string) }
    end

    def to_s
      conditions.map { |c| c.is_a?(All) ? "(#{c})" : c.to_s }.join(' OR ')
    end

    def ==(other)
      other.is_a?(One) && conditions == other.conditions
    end
    alias eql? ==

    def hash
      [self.class, conditions].hash
    end
  end

  # Walks a parsed expression tree and derives the literal condition.
  class Analyzer
    E = Regexp::Expression

    def condition_for(exp)
      repetitions = exp.repetitions
      apply_repetition(base_condition(exp), repetitions.min, repetitions.max)
    end

    private

    # Repeating an exact fragment min times requires min concatenated copies
    # of it; repeating any other condition is idempotent. An open-ended
    # repetition (max != min) makes the fragment inexact.
    def apply_repetition(condition, min, max)
      return Any.instance if min.zero?
      return condition unless condition.is_a?(Literal)
      return condition if min == 1 && max == 1
      return condition unless condition.exact?

      Literal.new(condition.text * min,
                  case_insensitive: condition.case_insensitive?,
                  prefix: condition.prefix?,
                  suffix: condition.suffix?,
                  exact: min == max)
    end

    def base_condition(exp)
      case exp
      when E::Alternation
        One.build(exp.alternatives.map { |alt| sequence_condition(alt) })
      when E::Conditional::Expression
        conditional_condition(exp)
      when E::Assertion::NegativeLookahead, E::Assertion::NegativeLookbehind,
           E::Group::Absence
        Any.instance # negative assertions must not become requirements
      when E::Assertion::Lookahead, E::Assertion::Lookbehind
        # Wrapped in All so the fragment cannot merge with neighboring
        # literals: assertion contents overlap the surrounding text.
        inner = sequence_condition(exp)
        inner.is_a?(Any) ? Any.instance : All.new([inner])
      when E::Root, E::Sequence, E::Group::Base
        sequence_condition(exp)
      when E::Literal
        literal_condition(exp.text, exp)
      when E::EscapeSequence::Base
        escape_condition(exp)
      else
        # Character sets/types, backreferences, properties, unknown nodes:
        # no literal requirement can be derived safely.
        Any.instance
      end
    end

    def conditional_condition(exp)
      branches = exp.branches.map { |branch| sequence_condition(branch) }
      # A missing else-branch matches the empty string.
      branches << Any.instance if branches.length < 2
      One.build(branches)
    end

    # Combines the conditions of a sequence of expressions with AND,
    # merging adjacent required literals into longer fragments.
    def sequence_condition(exp)
      parts = []
      pending = nil
      flush = lambda do
        parts << pending if pending
        pending = nil
      end

      exp.expressions.each do |sub|
        next if transparent?(sub)

        if sub.is_a?(E::Assertion::Lookahead) || sub.is_a?(E::Assertion::Lookbehind)
          inner = condition_for(sub)
          parts << inner unless inner.is_a?(Any)
          next
        end

        condition = condition_for(sub)
        unless condition.is_a?(Literal)
          flush.call
          parts << condition unless condition.is_a?(Any)
          next
        end

        merged =
          if pending && condition.prefix? &&
             pending.case_insensitive? == condition.case_insensitive?
            begin
              Literal.new(pending.text + condition.text,
                          case_insensitive: pending.case_insensitive?,
                          prefix: pending.prefix?,
                          suffix: condition.suffix?,
                          exact: pending.exact? && condition.exact?)
            rescue Encoding::CompatibilityError
              # e.g. a UTF-8 fragment next to raw bytes from a //n escape
              flush.call
              condition
            end
          else
            flush.call
            condition
          end

        if condition.exact?
          pending = merged
        elsif condition.suffix?
          # e.g. the "b" in /ab+c/: "ab" is required, and the last "b" may
          # still merge with what follows, but the chain cannot continue.
          parts << merged
          pending = condition
        else
          # e.g. the "foo" in /(?:foo|foobar)x/: not a guaranteed suffix of
          # the consumption, so it cannot merge with what follows.
          parts << merged
          pending = nil
        end
      end
      flush.call

      All.build(parts)
    end

    # Zero-width expressions neither contribute requirements nor break the
    # adjacency of surrounding literals.
    def transparent?(exp)
      case exp
      when E::Anchor::Base, E::Keep::Mark, E::FreeSpace, E::Group::Comment,
           E::Assertion::NegativeLookahead, E::Assertion::NegativeLookbehind
        true
      when E::Group::Options
        exp.empty? # bare option switches like (?i) consume no input
      else
        false
      end
    end

    def literal_condition(text, exp)
      return Any.instance if text.empty?

      Literal.new(text, case_insensitive: exp.i?, prefix: true, suffix: true, exact: true)
    end

    # Derives the exact bytes an escape sequence matches. Byte-oriented
    # escapes (\x, \0, control/meta) yield their raw bytes so that //n
    # regexps with non-UTF-8 bytes are filtered correctly; \u codepoints
    # yield their UTF-8 encoding.
    def escape_condition(exp)
      text =
        case exp
        when E::EscapeSequence::CodepointList
          exp.chars.join
        when E::EscapeSequence::Codepoint, E::EscapeSequence::Literal
          exp.char
        when E::EscapeSequence::UTF8Hex
          exp.text.scan(/\h+/).map(&:hex).pack('C*')
        else
          codepoint = exp.codepoint
          codepoint < 0x100 ? codepoint.chr(::Encoding::BINARY) : codepoint.chr('utf-8')
        end
      literal_condition(text, exp)
    rescue StandardError
      Any.instance
    end
  end
end
