# frozen_string_literal: true

class Regexp::BacktrackingAnalysis::PathCounter
  CAP = 2

  def initialize(string, options = {})
    @string = string
    @options = options
    @characters = Regexp::BacktrackingAnalysis::Characters.new(options)
    @cache = {}
  end

  def ambiguous?(exp, from = 0, to = @string.length)
    counts(exp, from).fetch(to, 0) > 1
  end

  def matches?(exp, from = 0, to = @string.length)
    counts(exp, from).key?(to)
  end

  def ambiguous_prefix?(expressions, from, to)
    current = { from => 1 }
    expressions.each do |child|
      next if skip?(child)

      following = {}
      current.each_key { |position| merge_into(following, counts(child, position)) }
      current = capped_counts(following)
      return false if current.empty?
    end
    current.fetch(to, 0) > 1
  end

  def ambiguous_followed_by?(exp, following, from = 0, to = @string.length)
    start = to - following.length
    return false unless @string.slice(start, following.length) == following

    closure_decomposition_counts(exp, from).fetch(start, 0) > 1
  end

  def closure_decomposition_counts(exp, from)
    body = exp.quantified? ? exp.unquantified_clone : exp
    min = exp.quantified? ? exp.quantifier.min : 1
    layer = { from => 1 }
    result = min.zero? ? { from => 1 } : {}
    limit = @string.length

    limit.times do
      current = {}
      layer.each_key do |position|
        maps = base_counts(body, position)
        maps.each_key do |endpoint|
          current[endpoint] = [current.fetch(endpoint, 0) + layer.fetch(position, 0), CAP].min
        end
      end
      break if current.empty?

      layer = current
      merge_into(result, layer)
    end
    result
  end

  def counts(exp, from = 0)
    key = [exp.object_id, from]
    @cache[key] ||= capped_counts(uncapped_counts(exp, from))
  end

  private

  def uncapped_counts(exp, from)
    if exp.quantified?
      if exp.possessive?
        possessive_counts(exp, from)
      else
        flexible_counts(exp, from)
      end
    else
      base_counts(exp, from)
    end
  end

  def base_counts(exp, from)
    case exp
    when Regexp::Expression::Alternation
      merge_counts(exp.expressions.map { |alt| counts(alt, from) })
    when Regexp::Expression::CharacterSet
      terminal_counts(exp, from)
    when Regexp::Expression::Group::Atomic
      atomic_counts(exp, from)
    when Regexp::Expression::Subexpression
      sequence_counts(exp.expressions, from)
    else
      terminal_counts(exp, from)
    end
  end

  def terminal_counts(exp, from)
    if exp.is_a?(Regexp::Expression::Literal)
      text = exp.to_s(:base)
      to = from + text.length
      return {} if to > @string.length
      return @string.slice(from, text.length) == text ? { to => 1 } : {}
    end

    return {} if from >= @string.length

    char = @string[from]
    begin
      @characters.matches?(exp, char) ? { from + 1 => 1 } : {}
    rescue Regexp::BacktrackingAnalysis::UnsupportedFeature
      {}
    end
  end

  def sequence_counts(expressions, from)
    current = { from => 1 }
    expressions.each do |child|
      next if skip?(child)

      following = {}
      current.each_key do |position|
        merge_into(following, counts(child, position))
      end
      current = capped_counts(following)
      return current if current.empty?
    end
    current
  end

  def flexible_counts(exp, from)
    min = exp.quantifier.min
    max = effective_max(exp)
    current = { from => 1 }
    result = min.zero? ? { from => 1 } : {}
    iterations = 0

    while iterations < max
      following = {}
      current.each_key { |position| merge_into(following, body_counts(exp, position)) }
      current = capped_counts(following)
      iterations += 1
      break if current.empty?

      merge_into(result, current) if iterations >= min
    end

    result
  end

  def possessive_counts(exp, from)
    counts = non_possessive_counts(exp, from)
    endpoint = exp.quantifier.lazy? ? counts.keys.min : counts.keys.max
    endpoint ? { endpoint => 1 } : {}
  end

  def non_possessive_counts(exp, from)
    clone = exp.clone
    quantifier = exp.quantifier.clone
    quantifier.text = quantifier.text.sub(/\+\z/, '')
    clone.quantifier = quantifier
    flexible_counts(clone, from)
  end

  def atomic_counts(exp, from)
    found = sequence_counts(exp.expressions, from)
    found.empty? ? {} : { found.keys.max => 1 }
  end

  def body_counts(exp, from)
    base = exp.unquantified_clone
    base_counts(base, from)
  end

  def effective_max(exp)
    max = exp.quantifier.max
    max < 0 ? @string.length + 1 : [max, @string.length + 1].min
  end


  def merge_counts(maps)
    result = {}
    maps.each { |map| merge_into(result, map) }
    capped_counts(result)
  end

  def merge_into(result, map)
    map.each do |position, count|
      result[position] = [result.fetch(position, 0) + count, CAP].min
    end
  end

  def capped_counts(map)
    map
  end

  def skip?(exp)
    exp.decorative? ||
      (exp.is_a?(Regexp::Expression::Group::Options) && exp.token == :options_switch)
  end
end
