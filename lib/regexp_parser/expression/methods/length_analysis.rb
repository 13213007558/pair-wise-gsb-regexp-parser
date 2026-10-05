# frozen_string_literal: true

# Bounded length analysis for regular expressions.
#
# Regexp::MatchLength derives an overall min/max and treats each
# backreference as independent of its target. That is not sound for
# length-checking field protocols: in /(a{1,3})\1/ the backreference
# re-matches exactly what group 1 captured, so only even total lengths
# can occur. This analysis therefore tracks the feasible combinations
# of total match length and individual capture group lengths, keeping
# correlated lengths correlated.
#
# Scope of this first version:
#
# - terminals have a fixed width (literal, set, type, escape, ...),
#   i.e. the character domain is finite
# - quantifiers must be bounded; '*', '+' and '{n,}' raise NotAnalyzable
# - numbered and named backreferences are supported; subexp calls and
#   recursion levels raise NotAnalyzable (they may recurse without bound)
# - a group that does not participate in a match has length nil
# - when a group captures repeatedly, the last capture wins
# - a backreference to a group that did not participate never matches
#   (Ruby/Onigmo semantics), so such states are dropped
# - multiplexed references (duplicate group names) resolve to the
#   highest-numbered participating target
# - lookarounds, conditionals and absence groups raise NotAnalyzable;
#   their length effects cannot be tracked soundly
#
# The number of tracked states (length + capture assignment pairs) is
# capped to keep pathological expressions from exploding. Exceeding the
# cap raises StateLimitExceeded instead of silently truncating results,
# so a successful analysis is always exact, never approximate.
class Regexp::LengthAnalysis
  include Enumerable

  DEFAULT_MAX_STATES = 10_000

  # base class for analysis errors
  class Error < Regexp::Parser::Error; end

  # raised for constructs outside the analyzable subset
  class NotAnalyzable < Error; end

  # raised when the number of states exceeds the configured limit
  class StateLimitExceeded < Error; end

  def self.of(obj, max_states: DEFAULT_MAX_STATES)
    exp = obj.is_a?(Regexp::Expression::Base) ? obj : Regexp::Parser.parse(obj)
    new(exp, max_states: max_states)
  end

  def initialize(exp, max_states: DEFAULT_MAX_STATES)
    @max_states = max_states
    collect_groups(exp)
    states = evaluate(exp, [[0, {}]])
    @tuples = states.map { |total, caps| [total, *group_numbers.map { |num| caps[num] }] }
                    .uniq
                    .sort_by { |tuple| tuple.map { |len| len.nil? ? -1 : len } }
                    .freeze
  end

  attr_reader :max_states, :group_numbers

  def group_names
    named_groups.keys
  end

  # Feasible [total_length, group_1_length, ...] tuples, sorted.
  # nil marks a group that does not participate in the match.
  attr_reader :tuples

  def each(&block)
    tuples.each(&block)
  end

  def total_lengths
    tuples.map(&:first).uniq
  end

  # Feasible lengths of the given group (number or name), excluding nil.
  def group_lengths(ref)
    index = group_index(ref)
    tuples.map { |tuple| tuple[index] }.compact.uniq
  end

  def inspect
    "#<#{self.class} tuples=#{tuples.inspect}>"
  end

  private

  E = Regexp::Expression

  UNIT_WIDTH = [
    E::CharacterSet,
    E::CharacterSet::Intersection,
    E::CharacterSet::IntersectedSequence,
    E::CharacterSet::Range,
    E::CharacterType::Base,
    E::EscapeSequence::Base,
    E::PosixClass,
    E::UnicodeProperty::Base,
  ].freeze

  ZERO_WIDTH = [
    E::Anchor::Base,
    E::Conditional::Condition,
    E::FreeSpace,
    E::Keep::Mark,
  ].freeze

  SUBEXP_CALLS = [
    E::Backreference::NumberCall,
    E::Backreference::NameCall,
    E::Backreference::NumberCallRelative,
    E::Backreference::NumberRecursionLevel,
    E::Backreference::NameRecursionLevel,
  ].freeze

  attr_reader :named_groups

  def collect_groups(exp)
    exps = exp.is_a?(E::Subexpression) ? exp.flat_map(true) { |e| e } : [exp]
    captures = exps.select { |e| e.is_a?(E::Group::Capture) }
    @group_numbers = captures.map(&:number).uniq.sort.freeze
    @named_groups = {}
    captures.each do |cap|
      next unless cap.is_a?(E::Group::Named)

      (named_groups[cap.name] ||= []) << cap.number
    end
    named_groups.freeze
  end

  # Applies the expression's own quantifier, if any.
  def evaluate(exp, states)
    min = exp.repetitions.min
    max = exp.repetitions.max
    if max == Float::INFINITY
      raise NotAnalyzable, "unbounded quantifier in #{exp.to_s.inspect}: " +                           'length analysis requires bounded repetitions'
    end

    acc = states
    out = min.zero? ? states.dup : []
    max.times do |i|
      acc = evaluate_unquantified(exp, acc)
      out.concat(acc) if i + 1 >= min
      out.uniq!
      check_limit!(out)
    end
    out
  end

  def evaluate_unquantified(exp, states)
    case exp
    when E::Literal
      advance(states, exp.text.length)
    when E::EscapeSequence::CodepointList
      advance(states, exp.codepoints.count)
    when *UNIT_WIDTH
      advance(states, 1)
    when *ZERO_WIDTH
      states
    when E::Assertion::Base
      raise NotAnalyzable, "cannot analyze #{exp.class}: " +                           'lookaround contents are not length-tracked'
    when E::Conditional::Expression
      raise NotAnalyzable, 'cannot analyze conditional expressions'
    when E::Group::Absence
      raise NotAnalyzable, 'cannot analyze absence groups (?~...): unbounded length'
    when *SUBEXP_CALLS
      raise NotAnalyzable, "cannot analyze subexp call #{exp.text.inspect}: " +                           'calls may recurse without bound'
    when E::Backreference::Base
      resolve_backreference(exp, states)
    when E::Alternation
      exp.expressions.flat_map { |alt| evaluate(alt, states) }
    when E::Group::Capture
      states.flat_map do |length, caps|
        evaluate_sequence(exp, [[0, caps]]).map do |inner_length, new_caps|
          [length + inner_length, new_caps.merge(exp.number => inner_length)]
        end
      end
    when E::Subexpression
      evaluate_sequence(exp, states)
    else
      raise NotAnalyzable, "cannot analyze #{exp.class}"
    end
  end

  def evaluate_sequence(exp, states)
    exp.expressions.each do |child|
      states = evaluate(child, states)
      check_limit!(states)
    end
    states
  end

  def resolve_backreference(exp, states)
    targets = exp.referenced_expressions
    if targets.nil? || targets.empty?
      raise NotAnalyzable, "unresolved reference #{exp.text.inspect} - not parsed?"
    end
    numbers = targets.map { |t| t.number if t.is_a?(E::Group::Capture) }.compact
    if numbers.empty?
      raise NotAnalyzable, "reference #{exp.text.inspect} does not target a capture group"
    end
    states.each_with_object([]) do |(length, caps), out|
      ref_length = numbers.reverse.map { |num| caps[num] }.compact.first
      out << [length + ref_length, caps] if ref_length
    end
  end

  def advance(states, width)
    states.map { |length, caps| [length + width, caps] }
  end

  def check_limit!(states)
    return unless states.size > max_states

    raise StateLimitExceeded, "state limit of #{max_states} exceeded: the expression " +                              'produces too many distinct length/capture combinations; ' +                              'increase :max_states or simplify the expression'
  end

  def group_index(ref)
    number =
      case ref
      when Integer
        ref
      when String, Symbol
        numbers = named_groups[ref.to_s]
        raise ArgumentError, "unknown group name: #{ref}" unless numbers
        unless numbers.one?
          raise ArgumentError, "ambiguous group name: #{ref}; use a group number"
        end
        numbers.first
      else
        raise ArgumentError, "invalid group reference: #{ref.inspect}"
      end
    index = group_numbers.index(number)
    raise ArgumentError, "unknown group number: #{number}" unless index

    index + 1 # tuple column 0 is the total length
  end
end

module Regexp::Expression
  class Base
    def length_analysis(max_states: Regexp::LengthAnalysis::DEFAULT_MAX_STATES)
      Regexp::LengthAnalysis.of(self, max_states: max_states)
    end
  end
end
