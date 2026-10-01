# frozen_string_literal: true

class Regexp::BacktrackingAnalysis::Support
  def self.supported?(root)
    new(root).supported?
  end

  def self.unsupported(root)
    new(root).unsupported
  end

  def self.terminals(root, max_length = 4)
    new(root).terminals(max_length)
  end

  def initialize(root)
    @root = root
  end

  def supported?
    unsupported.nil?
  end

  def unsupported
    @root.each_expression(true) do |exp|
      next if supported_node?(exp)

      return Regexp::BacktrackingAnalysis::UnsupportedFeature.new(
        "unsupported expression #{exp.to_s.inspect}", exp
      )
    rescue Regexp::BacktrackingAnalysis::UnsupportedFeature => error
      return error
    end
    nil
  end

  def terminals(max_length)
    words = []
    each_terminal_word(@root, '', words, max_length)
    words.select { |word| !word.empty? }.uniq.first(48)
  end

  private

  def supported_node?(exp)
    case exp
    when Regexp::Expression::Root,
         Regexp::Expression::Alternative
      true
    when Regexp::Expression::FreeSpace,
         Regexp::Expression::Group::Comment
      true
    when Regexp::Expression::Group::Options
      exp.token == :options
    when Regexp::Expression::Group::Base
      exp.is_a?(Regexp::Expression::Group::Passive) ||
        exp.is_a?(Regexp::Expression::Group::Capture) ||
        exp.is_a?(Regexp::Expression::Group::Atomic)
    when Regexp::Expression::Alternation
      true
    when Regexp::Expression::Literal
      true
    when Regexp::Expression::EscapeSequence::Base
      supported_escape?(exp)
    when Regexp::Expression::CharacterType::Base
      exp.token != :xgrapheme
    when Regexp::Expression::CharacterSet
      supported_set?(exp)
    when Regexp::Expression::PosixClass
      %w[digit xdigit alpha alnum word space blank lower upper punct print graph cntrl]
        .include?(exp.name)
    else
      false
    end
  end

  def supported_escape?(exp)
    exp.is_a?(Regexp::Expression::EscapeSequence::Literal) ||
      exp.is_a?(Regexp::Expression::EscapeSequence::AsciiEscape) ||
      exp.is_a?(Regexp::Expression::EscapeSequence::Backspace) ||
      exp.is_a?(Regexp::Expression::EscapeSequence::Bell) ||
      exp.is_a?(Regexp::Expression::EscapeSequence::FormFeed) ||
      exp.is_a?(Regexp::Expression::EscapeSequence::Newline) ||
      exp.is_a?(Regexp::Expression::EscapeSequence::Return) ||
      exp.is_a?(Regexp::Expression::EscapeSequence::Tab) ||
      exp.is_a?(Regexp::Expression::EscapeSequence::VerticalTab) ||
      exp.is_a?(Regexp::Expression::EscapeSequence::Octal) ||
      exp.is_a?(Regexp::Expression::EscapeSequence::Hex) ||
      exp.is_a?(Regexp::Expression::EscapeSequence::Codepoint) ||
      exp.is_a?(Regexp::Expression::EscapeSequence::UTF8Hex) ||
      exp.is_a?(Regexp::Expression::EscapeSequence::Control) ||
      exp.is_a?(Regexp::Expression::EscapeSequence::Meta) ||
      exp.is_a?(Regexp::Expression::EscapeSequence::MetaControl)
  end

  def supported_set?(exp)
    exp.expressions.all? do |child|
      if child.is_a?(Regexp::Expression::CharacterSet::Intersection)
        child.expressions.all? do |sequence|
          sequence.expressions.all? { |member| supported_set_member?(member) }
        end
      else
        supported_set_member?(child)
      end
    end
  end

  def supported_set_member?(exp)
    return true if exp.is_a?(Regexp::Expression::Literal)
    return true if exp.is_a?(Regexp::Expression::PosixClass) && supported_node?(exp)
    return true if exp.is_a?(Regexp::Expression::EscapeSequence::Base) && supported_escape?(exp)

    if exp.is_a?(Regexp::Expression::CharacterSet::Range)
      return exp.expressions.all? do |endpoint|
        endpoint.is_a?(Regexp::Expression::Literal) ||
          (endpoint.is_a?(Regexp::Expression::EscapeSequence::Base) && supported_escape?(endpoint))
      end
    end

    false
  end

  def each_terminal_word(exp, prefix, words, max_length)
    return if prefix.length >= max_length

    if terminal_word?(exp)
      append_terminal_word(words, prefix, terminal_text(exp), max_length)
      return
    end

    terminal_candidates(exp).each do |word|
      append_terminal_word(words, prefix, word, max_length)
    end

    if exp.terminal?
      return
    end

    if exp.is_a?(Regexp::Expression::Alternation)
      exp.expressions.each do |alternative|
        each_sequence_word(alternative, prefix, words, max_length)
      end
    else
      each_sequence_word(exp, prefix, words, max_length)
    end
  end

  def each_sequence_word(sequence, prefix, words, max_length)
    current = prefix
    sequence.expressions.each do |child|
      next if skip?(child)

      base = child.quantified? ? child : child
      if terminal_word?(base)
        current += terminal_text(base)
      elsif !base.terminal?
        each_terminal_word(base, current, words, max_length)
        return
      end
      return if current.length > max_length
    end
    append_terminal_word(words, '', current, max_length) unless current.empty?
  end

  def append_terminal_word(words, prefix, addition, max_length)
    word = prefix + addition
    return if word.empty? || word.length > max_length

    words << word unless words.include?(word)
  end

  def terminal_word?(exp)
    exp.is_a?(Regexp::Expression::Literal) ||
      (exp.is_a?(Regexp::Expression::EscapeSequence::Base) &&
        exp.respond_to?(:char) && !exp.is_a?(Regexp::Expression::EscapeSequence::CodepointList))
  end

  def terminal_text(exp)
    return exp.to_s(:base) if exp.is_a?(Regexp::Expression::Literal)

    exp.char
  end

  def terminal_candidates(exp)
    candidates = %w[a b 0 1 z A _ . -] + [" ", "\n", "\t"]
    root_options = @root.options || {}
    candidates.select do |char|
      begin
        Regexp::BacktrackingAnalysis::Characters.matches?(
          exp,
          char,
          root_options.merge(exp.options || {})
        )
      rescue Regexp::BacktrackingAnalysis::UnsupportedFeature
        false
      end
    end
  end

  def skip?(exp)
    exp.decorative? ||
      (exp.is_a?(Regexp::Expression::Group::Options) && exp.token == :options_switch)
  end
end
