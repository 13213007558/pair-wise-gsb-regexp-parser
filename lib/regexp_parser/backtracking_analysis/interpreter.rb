# frozen_string_literal: true

class Regexp::BacktrackingAnalysis::Interpreter
  COMMIT = :regexp_backtracking_analysis_commit

  attr_reader :steps

  def self.match?(root, string, options = {})
    interpreter = new(root, options)
    interpreter.match?(string)
  end

  def self.steps(root, string, options = {})
    interpreter = new(root, options)
    interpreter.match?(string)
    interpreter.steps
  end

  def initialize(root, options = {})
    @root = root
    @options = options
    @characters = Regexp::BacktrackingAnalysis::Characters.new(options)
    @steps = 0
  end

  def match?(string)
    @string = string
    match_sequence(@root.expressions, 0, 0, proc do |position|
      position == @string.length ? position : nil
    end) == @string.length
  end

  private

  def match_sequence(expressions, index, position, continuation)
    while index < expressions.length
      child = expressions[index]

      if skip?(child)
        index += 1
        next
      end

      return match_node(child, position, proc do |after_child|
        match_sequence(expressions, index + 1, after_child, continuation)
      end)
    end

    continuation.call(position)
  end

  def match_node(exp, position, continuation)
    if exp.quantified?
      match_quantified(exp, position, continuation)
    elsif exp.is_a?(Regexp::Expression::Alternation)
      match_alternation(exp, position, continuation)
    elsif exp.is_a?(Regexp::Expression::Group::Atomic)
      match_atomic(exp, position, continuation)
    elsif exp.terminal? || exp.is_a?(Regexp::Expression::CharacterSet)
      match_terminal(exp, position, continuation)
    else
      match_sequence(exp.expressions, 0, position, continuation)
    end
  end

  def match_alternation(exp, position, continuation)
    exp.expressions.each do |alternative|
      result = match_sequence(alternative.expressions, 0, position, continuation)
      return result unless result.nil?
    end
    nil
  end

  def match_atomic(exp, position, continuation)
    catch(COMMIT) do
      match_sequence(exp.expressions, 0, position, proc do |after_group|
        result = continuation.call(after_group)
        throw(COMMIT, result) unless result.nil?
        nil
      end)
    end
  end

  def match_quantified(exp, position, continuation)
    if exp.possessive?
      endpoint = possessive_endpoint(exp, position)
      return endpoint.nil? ? nil : continuation.call(endpoint)
    end

    if exp.lazy?
      match_lazy(exp, position, 0, nil, continuation)
    else
      match_greedy(exp, position, 0, nil, continuation)
    end
  end

  def match_greedy(exp, position, count, last_position, continuation)
    if can_grow?(exp, count, position, last_position)
      result = match_body(exp, position, proc do |after_body|
        if after_body == position
          next nil
        else
          next match_greedy(exp, after_body, count + 1, position, continuation)
        end
      end)
      return result unless result.nil?
    end

    count >= exp.quantifier.min ? continuation.call(position) : nil
  end

  def match_lazy(exp, position, count, last_position, continuation)
    if count >= exp.quantifier.min
      result = continuation.call(position)
      return result unless result.nil?
    end

    return nil unless can_grow?(exp, count, position, last_position)

    match_body(exp, position, proc do |after_body|
      next nil if after_body == position

      match_lazy(exp, after_body, count + 1, position, continuation)
    end)
  end

  def match_body(exp, position, continuation)
    base = exp.unquantified_clone
    match_node(base, position, continuation)
  end

  def possessive_endpoint(exp, position)
    clone = exp.clone
    quantifier = exp.quantifier.clone
    quantifier.text = quantifier.text.sub(/\+\z/, '')
    clone.quantifier = quantifier
    endpoints = []
    enumerate_greedy_endpoints(clone, position, 0, nil, endpoints)
    endpoints.max
  end

  def enumerate_greedy_endpoints(exp, position, count, last_position, endpoints)
    if can_grow?(exp, count, position, last_position)
      match_body(exp, position, proc do |after_body|
        next nil if after_body == position

        enumerate_greedy_endpoints(exp, after_body, count + 1, position, endpoints)
      end)
    end

    endpoints << position if count >= exp.quantifier.min
  end

  def can_grow?(exp, count, position, last_position)
    (exp.quantifier.max < 0 || count < exp.quantifier.max) &&
      position != last_position &&
      count < @string.length
  end

  def match_terminal(exp, position, continuation)
    @steps += 1
    return nil if position >= @string.length

    if exp.is_a?(Regexp::Expression::Literal)
      text = exp.to_s(:base)
      after = position + text.length
      return nil if after > @string.length
      return nil unless @string.slice(position, text.length) == text

      continuation.call(after)
    else
      char = @string[position]
      matched = begin
        @characters.matches?(exp, char)
      rescue Regexp::BacktrackingAnalysis::UnsupportedFeature
        false
      end
      matched ? continuation.call(position + 1) : nil
    end
  end

  def skip?(exp)
    exp.decorative? ||
      (exp.is_a?(Regexp::Expression::Group::Options) && exp.token == :options_switch)
  end
end
