# frozen_string_literal: true

# Exact bounded match-length analysis. The analysis is exact as long as all
# quantifiers are bounded and the pattern does not contain one of the features
# that are explicitly rejected below.
class Regexp::BoundedMatchLength
  class AnalysisError < Regexp::Parser::Error; end

  class UnsupportedExpressionError < AnalysisError
    attr_reader :expression

    def initialize(message, expression)
      @expression = expression
      super(message)
    end
  end

  class StateLimitError < AnalysisError
    attr_reader :state_count, :state_limit

    def initialize(state_count, state_limit)
      @state_count = state_count
      @state_limit = state_limit
      super("bounded match length analysis exceeded #{state_limit} states " \
            "(#{state_count} reached); increase state_limit or simplify the pattern")
    end
  end

  Analysis = Struct.new(:lengths, :combinations, :state_count, :state_limit) do
    def minmax
      [lengths.min, lengths.max]
    end

    def inspect
      "#<Regexp::BoundedMatchLength::Analysis lengths=#{lengths.inspect} " \
        "combinations=#{combinations.inspect} state_count=#{state_count} " \
        "state_limit=#{state_limit}>"
    end
  end

  State = Struct.new(:length, :captures, :names) do
    def with(length_delta = 0)
      copy = dup
      copy.length += length_delta
      copy.captures = captures.dup
      copy.names = names.dup
      copy
    end
  end

  DEFAULT_STATE_LIMIT = 10_000

  def self.of(obj, groups: nil, state_limit: DEFAULT_STATE_LIMIT)
    exp = obj.is_a?(Regexp::Expression::Base) ? obj : Regexp::Parser.parse(obj)
    new(exp, state_limit).analyze(groups)
  end

  def initialize(exp, state_limit)
    @exp = exp
    @state_limit = state_limit
    @state_count = 0
  end

  def analyze(selected_groups = nil)
    initial_state = State.new(0, {}, {})
    states = apply(@exp, initial_state)
    groups = normalize_groups(selected_groups)
    combinations = build_combinations(states, groups)

    Analysis.new(states.map(&:length).uniq.sort, combinations, @state_count, @state_limit)
  end

  private

  def build_combinations(states, groups)
    grouped = states.group_by do |state|
      state.length
    end.transform_values do |length_states|
      length_states.map do |state|
        groups.map do |group|
          if group.is_a?(Symbol)
            capture = state.names[group]
            capture && state.captures[capture]
          else
            state.captures[group]
          end
        end
      end.uniq
    end
    grouped.sort_by(&:first).flat_map do |length, values|
      values.map { |tuple| [length, tuple] }
    end
  end

  def normalize_groups(groups)
    captures = each_expression(@exp).select { |exp| exp.is_a?(Regexp::Expression::Group::Capture) }
    capture_numbers = captures.map(&:number)
    return capture_numbers if groups.nil?

    Array(groups).map do |group|
      case group
      when Integer
        unsupported!("unknown capture group #{group.inspect}") unless capture_numbers.include?(group)
        group
      when String, Symbol
        name = group.to_sym
        known = captures.any? { |exp| exp.respond_to?(:name) && exp.name.to_sym == name }
        unsupported!("unknown named capture #{name.inspect}") unless known
        name
      else
        unsupported!("capture group must be an Integer, String, or Symbol, got #{group.class}")
      end
    end
  end

  def each_expression(exp)
    result = []
    walk = lambda do |current|
      result << current
      current.each { |child| walk.call(child) } unless current.terminal?
    end
    walk.call(exp)
    result
  end

  def apply(exp, state)
    base_states = apply_unquantified(exp, state)
    apply_repetitions(exp, state, base_states)
  end

  def apply_repetitions(exp, state, states)
    repetitions = exp.repetitions
    return states if repetitions.min == 1 && repetitions.max == 1
    unsupported!("unbounded quantifiers are not supported", exp) if repetitions.max == Float::INFINITY

    repetitions.min.upto(repetitions.max).flat_map do |count|
      repeated =
        if count.zero?
          [state.dup]
        elsif count == 1
          states
        else
          apply_unquantified_clone(exp, [state.dup], count)
        end
      add_states(repeated)
    end
  end

  def apply_unquantified_clone(exp, states, remaining = 1)
    clone = exp.unquantified_clone
    states = states.flat_map do |state|
      if clone.is_a?(Regexp::Expression::Group::Capture)
        apply_capture_body(clone, state, assign: remaining == 1)
      else
        apply(clone, state)
      end
    end
    remaining == 1 ? states : apply_unquantified_clone(exp, add_states(states), remaining - 1)
  end

  def apply_unquantified(exp, state)
    case exp
    when Regexp::Expression::Literal
      advance(state, char_length(exp.text))
    when Regexp::Expression::EscapeSequence::CodepointList
      advance(state, exp.codepoints.count)
    when Regexp::Expression::Assertion::Base,
         Regexp::Expression::Group::Absence,
         Regexp::Expression::Conditional::Condition,
         Regexp::Expression::Conditional::Expression,
         Regexp::Expression::CharacterType::ExtendedGrapheme,
         Regexp::Expression::CharacterType::Linebreak
      unsupported!("#{exp.class.name} is not supported by bounded match length analysis", exp)
    when Regexp::Expression::Group::Capture
      apply_capture(exp, state)
    when Regexp::Expression::Alternation
      apply_alternatives(exp, state)
    when Regexp::Expression::Backreference::Base
      apply_backreference(exp, state)
    when Regexp::Expression::Subexpression
      apply_sequence(exp, state)
    when Regexp::Expression::CharacterSet,
         Regexp::Expression::CharacterType::Base,
         Regexp::Expression::PosixClass,
         Regexp::Expression::UnicodeProperty::Base,
         Regexp::Expression::EscapeSequence::Base
      advance(state, 1)
    when Regexp::Expression::Anchor::Base,
         Regexp::Expression::FreeSpace,
         Regexp::Expression::Keep::Mark
      [state]
    else
      unsupported!("#{exp.class.name} is not supported by bounded match length analysis", exp)
    end
  end

  def apply_sequence(exp, state)
    expressions = exp.expressions.reject do |child|
      child.is_a?(Regexp::Expression::Group::Comment)
    end
    expressions.reduce([state]) do |states, child|
      add_states(states.flat_map { |current| apply(child, current) })
    end
  end

  def apply_capture(exp, state)
    apply_repetitions(exp, state, apply_capture_body(exp, state, assign: true))
  end

  def apply_capture_body(exp, state, assign: true)
    states = apply_sequence(exp, state)
    return states unless assign

    add_states(states.map do |child_state|
      captured_length = child_state.length - state.length
      capture_state = child_state.with(0)
      capture_state.captures[exp.number] = captured_length
      if exp.is_a?(Regexp::Expression::Group::Named)
        capture_state.names[exp.name.to_sym] = exp.number
      end
      capture_state
    end)
  end

  def apply_alternatives(exp, state)
    exp.alternatives.flat_map do |alternative|
      apply(alternative, state)
    end
  end

  def apply_backreference(exp, state)
    if exp.is_a?(Regexp::Expression::Backreference::NumberCall) ||
       exp.is_a?(Regexp::Expression::Backreference::NameCall) ||
       exp.is_a?(Regexp::Expression::Backreference::NumberRecursionLevel) ||
       exp.is_a?(Regexp::Expression::Backreference::NameRecursionLevel)
      unsupported!("subexpression calls and recursion are not supported", exp)
    end

    length = backreference_length(exp, state)
    return [] if length.nil?

    repetitions = exp.repetitions
    repetitions.min.upto(repetitions.max).map do |count|
      state.with(length * count)
    end
  end

  def backreference_length(exp, state)
    target = backreference_target(exp, state)
    state.captures[target]
  end

  def backreference_target(exp, state)
    if exp.is_a?(Regexp::Expression::Backreference::Number)
      exp.reference
    else
      state.names[exp.reference.to_sym]
    end
  end

  def advance(state, length)
    [state.with(length)]
  end

  def add_states(states)
    unique = states.uniq
    @state_count = [@state_count, unique.size].max
    raise StateLimitError.new(unique.size, @state_limit) if unique.size > @state_limit
    unique
  end

  def char_length(text)
    text.length
  end

  def unsupported!(message, expression = @exp)
    raise UnsupportedExpressionError.new(message, expression)
  end
end

module Regexp::Expression
  BoundedMatchLength = Regexp::BoundedMatchLength

  class Base
    def bounded_match_length(groups: nil, state_limit: Regexp::BoundedMatchLength::DEFAULT_STATE_LIMIT)
      Regexp::BoundedMatchLength.of(self, groups: groups, state_limit: state_limit)
    end
  end
end
