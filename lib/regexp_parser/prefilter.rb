# frozen_string_literal: true

# Derives a "required literal" prefilter condition from a parsed regular
# expression. The condition is a conservative approximation: it is guaranteed
# to accept every string that the original expression matches, so it can be
# used to cheaply reject non-matching strings (e.g. via String#include?)
# before running the full regular expression.
#
# Example:
#
#   condition = Regexp::Prefilter.derive(/(?:alpha|beta).*end/)
#   condition.to_s # => '("alpha" | "beta") & "end"'
#   condition.match?('xxalphayyendzz') # => true
#   condition.match?('alpha')          # => false
#
# Whenever there is no reliable condition (optional branches, zero-width or
# unknown constructs, backreferences, ...), the affected part degrades to a
# tautology that accepts everything, so matching text is never rejected.
module Regexp::Prefilter
  # Builds the prefilter condition for a Regexp, String, or
  # Regexp::Expression::Base.
  #
  # Options:
  # - min_length:   literals shorter than this many characters are dropped
  #                 (replaced by a tautology). Default: 1 (keep all).
  # - max_literals: if the resulting condition references more literals than
  #                 this, it collapses to a tautology. Default: 32.
  def self.derive(obj, min_length: 1, max_literals: 32)
    exp = obj.is_a?(Regexp::Expression::Base) ? obj : Regexp::Parser.parse(obj)
    condition = exp.required_literal_condition
    condition = condition.prune(min_length) if min_length > 1
    condition = Condition.tautology if condition.literal_count > max_literals
    condition
  end

  # Abstract base class of the condition tree. Subclasses: Tautology,
  # Literal, All (AND), Any (OR).
  class Condition
    class << self
      def tautology
        Tautology::INSTANCE
      end

      def literal(text, case_insensitive: false, ts: nil, te: nil)
        return tautology if text.empty?

        Literal.new(text, case_insensitive, ts, te)
      end

      # AND-combination. Adjacent literals with equal case sensitivity are
      # merged into one, since adjacent required literals in a sequence match
      # contiguous text. Tautologies break such runs and are then dropped.
      def all(children)
        merged = []
        children.each do |child|
          if child.is_a?(Literal) && merged.last.is_a?(Literal) &&
             merged.last.case_insensitive? == child.case_insensitive?
            begin
              merged[-1] = merged.last.merge(child)
            rescue Encoding::CompatibilityError
              merged << child
            end
          else
            merged << child
          end
        end
        merged.reject!(&:tautology?)
        case merged.length
        when 0 then tautology
        when 1 then merged.first
        else All.new(merged)
        end
      end

      # OR-combination. A tautological branch makes the whole disjunction
      # tautological.
      def any(children)
        return tautology if children.empty? || children.any?(&:tautology?)
        return children.first if children.length == 1

        Any.new(children)
      end
    end

    def tautology?
      false
    end

    def literals
      []
    end

    def literal_count
      literals.count
    end

    # The range in the original pattern source that contributed the literals
    # of this condition, or nil if it has none.
    def source_range
      nil
    end

    def prune(_min_length)
      self
    end

    def ===(string)
      match?(string)
    end
  end

  # Accepts every string. Used when no reliable required literal exists.
  class Tautology < Condition
    INSTANCE = new

    def tautology?
      true
    end

    def match?(_string)
      true
    end

    def to_s
      'TRUE'
    end

    def ==(other)
      other.is_a?(Tautology)
    end
  end

  # A literal string that must occur in the haystack. Case-insensitive
  # literals are checked through a Regexp so that case folding behaves
  # exactly like the regular expression engine's.
  class Literal < Condition
    attr_reader :text, :ts, :te

    def initialize(text, case_insensitive, ts, te)
      @text = text
      @case_insensitive = case_insensitive
      @ts = ts
      @te = te
    end

    def case_insensitive?
      @case_insensitive
    end

    def merge(other)
      Literal.new(text + other.text, case_insensitive?, ts, other.te)
    end

    def match?(string)
      if case_insensitive?
        ci_regexp.match?(string)
      else
        string.include?(text)
      end
    rescue Encoding::CompatibilityError, ArgumentError
      true # never reject on encoding mismatches
    end

    def literals
      [self]
    end

    def source_range
      ts && te ? (ts...te) : nil
    end

    def prune(min_length)
      text.length < min_length ? Condition.tautology : self
    end

    def to_s
      case_insensitive? ? "#{text.inspect}/i" : text.inspect
    end

    def ==(other)
      other.is_a?(Literal) &&
        text == other.text &&
        case_insensitive? == other.case_insensitive?
    end

    private

    def ci_regexp
      @ci_regexp ||= ::Regexp.new(::Regexp.escape(text), ::Regexp::IGNORECASE)
    end
  end

  # Abstract base class for All and Any.
  class Junction < Condition
    attr_reader :children

    def initialize(children)
      @children = children.freeze
    end

    def literals
      children.flat_map(&:literals)
    end

    def source_range
      ranges = children.map(&:source_range).compact
      return nil if ranges.empty?

      (ranges.map(&:begin).min...ranges.map(&:end).max)
    end

    def ==(other)
      other.instance_of?(self.class) && children == other.children
    end
  end

  # All children must hold.
  class All < Junction
    def match?(string)
      children.all? { |child| child.match?(string) }
    end

    def prune(min_length)
      Condition.all(children.map { |child| child.prune(min_length) })
    end

    def to_s
      children.map { |child| child.is_a?(Any) ? "(#{child})" : child.to_s }.join(' & ')
    end
  end

  # At least one child must hold.
  class Any < Junction
    def match?(string)
      children.any? { |child| child.match?(string) }
    end

    def prune(min_length)
      Condition.any(children.map { |child| child.prune(min_length) })
    end

    def to_s
      children.map { |child| child.is_a?(All) ? "(#{child})" : child.to_s }.join(' | ')
    end
  end
end
