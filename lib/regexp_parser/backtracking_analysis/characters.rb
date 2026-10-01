# frozen_string_literal: true

class Regexp::BacktrackingAnalysis::Characters
  def self.matches?(exp, char, options = nil)
    new(options || {}).matches?(exp, char)
  end

  def initialize(options = {})
    @options = options
  end

  def matches?(exp, char)
    options = exp.respond_to?(:options) ? @options.merge(exp.options || {}) : @options
    return self.class.new(options).send(:matches_with_options?, exp, char, options) unless options.equal?(@options)

    matches_with_options?(exp, char, @options)
  end

  private

  def matches_with_options?(exp, char, _options)
    case exp
    when Regexp::Expression::Literal
      literal_matches?(exp.to_s(:base), char)
    when Regexp::Expression::EscapeSequence::Base
      escape_matches?(exp, char)
    when Regexp::Expression::CharacterType::Base
      type_matches?(exp, char)
    when Regexp::Expression::CharacterSet
      set_matches?(exp, char)
    else
      raise Regexp::BacktrackingAnalysis::UnsupportedFeature.new(
        "unsupported terminal #{exp.class}", exp
      )
    end
  end

  def literal_matches?(text, char)
    if case_insensitive? && text.length == 1
      text.downcase == char.downcase
    else
      text == char
    end
  end

  def escape_matches?(exp, char)
    if exp.is_a?(Regexp::Expression::EscapeSequence::Literal) && exp.text.start_with?('\\')
      literal = exp.text[1..-1]
      return literal.downcase == char.downcase if case_insensitive? && literal.length == 1

      return literal == char
    end

    return exp.char == char if exp.respond_to?(:char)

    raise Regexp::BacktrackingAnalysis::UnsupportedFeature.new(
      "unsupported escape #{exp.to_s}", exp
    )
  end

  def type_matches?(exp, char)
    positive = !exp.negative?
    result =
      case exp.token
      when :digit, :nondigit then char =~ /[0-9]/
      when :hex, :nonhex then char =~ /[0-9a-fA-F]/
      when :word, :nonword then char =~ /[0-9A-Za-z_]/
      when :space, :nonspace then char =~ /[\t\n\v\f\r ]/
      when :linebreak then char == "\n"
      when :dot then char != "\n" || multiline?
      else
        raise Regexp::BacktrackingAnalysis::UnsupportedFeature.new(
          "unsupported character type #{exp.to_s}", exp
        )
      end
    !result == !positive
  end

  def set_matches?(exp, char)
    intersection = exp.expressions.detect do |child|
      child.is_a?(Regexp::Expression::CharacterSet::Intersection)
    end

    if intersection
      result = intersection.expressions.all? { |seq| sequence_matches?(seq, char) }
    else
    result = exp.expressions.any? { |child| set_member_matches?(child, char, false) }
    end

    exp.negative? ? !result : result
  end

  def sequence_matches?(sequence, char)
    sequence.expressions.any? { |child| set_member_matches?(child, char, false) }
  end

  def set_member_matches?(exp, char, parent_negative)
    return set_matches?(exp, char) if exp.is_a?(Regexp::Expression::CharacterSet)

    case exp
    when Regexp::Expression::CharacterSet::Range
      result = range_matches?(exp, char)
    when Regexp::Expression::PosixClass
      result = posix_matches?(exp, char)
    else
      result = matches?(exp, char)
    end
    parent_negative ? !result : result
  end

  def range_matches?(range, char)
    left = range[0]
    right = range[1]
    char >= character_value(left) && char <= character_value(right)
  end

  def character_value(exp)
    return exp.char if exp.is_a?(Regexp::Expression::EscapeSequence::Base) && exp.respond_to?(:char)
    return exp.to_s(:base) if exp.is_a?(Regexp::Expression::Literal)

    raise Regexp::BacktrackingAnalysis::UnsupportedFeature.new(
      "unsupported range endpoint #{exp.to_s}", exp
    )
  end

  def posix_matches?(exp, char)
    pattern =
      case exp.name
      when 'digit' then '[0-9]'
      when 'xdigit' then '[0-9a-fA-F]'
      when 'alpha' then '[A-Za-z]'
      when 'alnum' then '[0-9A-Za-z]'
      when 'word' then '[0-9A-Za-z_]'
      when 'space', 'blank' then '[\t\n\v\f\r ]'
      when 'lower' then '[a-z]'
      when 'upper' then '[A-Z]'
      when 'punct' then '[!-\/:-@\[-`{-~]'
      when 'print', 'graph' then '[ -~]'
      when 'cntrl' then '[\x00-\x1f\x7f]'
      else
        raise Regexp::BacktrackingAnalysis::UnsupportedFeature.new(
          "unsupported POSIX class #{exp.to_s}", exp
        )
      end
    result = !!(char =~ Regexp.new(pattern, nil, 'n'))
    exp.negative? ? !result : result
  end

  def case_insensitive?
    @options[:i] == true
  end

  def multiline?
    @options[:m] == true
  end
end
