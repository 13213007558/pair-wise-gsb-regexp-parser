# frozen_string_literal: true

class Regexp::RequiredLiteral
  # A conservative, string-based necessary condition for a regexp match.
  # Every string matched by the analyzed regexp is matched by this condition.
  # The inverse is intentionally not guaranteed.
  class Condition
    attr_reader :source_range

    def self.always(source_range = nil)
      Always.new(source_range)
    end

    def self.and(conditions, source_range = nil)
      And.new(conditions, source_range)
    end

    def self.or(conditions, source_range = nil)
      Or.new(conditions, source_range)
    end

    def initialize(source_range)
      @source_range = source_range
    end

    def always?
      false
    end

    def literal?
      false
    end

    def complexity
      0
    end

    def size
      0
    end

    def match?(_string)
      true
    end
    alias_method :===, :match?

    def to_a
      []
    end

    def each_literal(&block)
      return enum_for(__method__) unless block
    end

    def simplify
      self
    end

    private

    def compatible_encoding?(string)
      Encoding.compatible?(string, literal)
    rescue ArgumentError, Encoding::CompatibilityError
      false
    end

    def contains_literal?(string)
      if ignorecase
        casefold_include?(string, literal)
      else
        string.include?(literal)
      end
    end

    # String#casecmp? implements the same Unicode case folding as Regexp /i.
    # On Ruby versions without it we only create /i literals for ASCII text,
    # where byte comparison after ASCII folding is sound.
    def casefold_include?(string, literal)
      if String.method_defined?(:casecmp?)
        unicode_casefold_include?(string, literal)
      else
        ascii_casefold_include?(string, literal)
      end
    end

    def unicode_casefold_include?(string, literal)
      length = literal.length
      max_start = string.length - length
      index = 0

      while index <= max_start
        return true if literal.casecmp?(string[index, length])
        index += 1
      end

      false
    end

    def ascii_casefold_include?(string, literal)
      folded_literal = literal.downcase
      length = literal.length
      max_start = string.length - length
      index = 0

      while index <= max_start
        slice = string[index, length]
        return true if slice.ascii_only? && slice.downcase == folded_literal
        index += 1
      end

      false
    end

    def literal
      raise NotImplementedError
    end

    def ignorecase
      false
    end
  end

  class Always < Condition
    def always?
      true
    end

    def to_s
      'true'
    end
    alias_method :inspect, :to_s
  end

  class Literal < Condition
    attr_reader :literal, :ignorecase

    def initialize(literal, source_range, ignorecase: false)
      super(source_range)
      @literal = literal
      @ignorecase = ignorecase
    end

    def literal?
      true
    end

    def complexity
      literal.length
    end

    def size
      1
    end

    def match?(string)
      return false unless compatible_encoding?(string)

      contains_literal?(string)
    end

    def to_a
      [self]
    end

    def each_literal(&block)
      return enum_for(__method__) unless block
      block.call(self)
    end

    def to_s
      suffix = ignorecase ? 'i' : ''
      "include(#{literal.inspect}#{suffix})"
    end
    alias_method :inspect, :to_s
  end

  module Junction
    attr_reader :conditions

    def initialize(conditions, source_range = nil)
      @conditions = conditions
      super(source_range || joined_source_range(@conditions))
    end

    def complexity
      @complexity ||= begin
        own = conditions.length
        own + conditions.map(&:complexity).inject(0, :+)
      end
    end

    def size
      conditions.map(&:size).inject(0, :+)
    end

    def to_a
      [self]
    end

    def each_literal(&block)
      return enum_for(__method__) unless block
      conditions.each { |condition| condition.each_literal(&block) }
    end

    def simplify
      return Condition.always(source_range) if conditions.empty? && empty_is_always?
      return conditions.first if conditions.length == 1

      simplified = conditions.map(&:simplify)
      return Condition.always(source_range) if contains_always?(simplified)

      simplified = simplified.flat_map do |condition|
        same_junction?(condition) ? condition.conditions : [condition]
      end
      rebuilt = rebuild(simplified.flat_map(&:to_a))
      return rebuilt if rebuilt.conditions.length == conditions.length

      rebuilt.simplify
    end

    def to_s
      "#{operator_name}(#{conditions.map(&:to_s).join(', ')})"
    end
    alias_method :inspect, :to_s

    private

    def joined_source_range(conditions)
      ranges = conditions.map(&:source_range).compact
      return nil if ranges.empty?

      starts = ranges.map(&:first)
      ends = ranges.map(&:last)
      [starts.min, ends.max]
    end

    def rebuild(conditions)
      self.class.new(conditions, source_range)
    end
  end

  class And < Condition
    include Junction

    def match?(string)
      conditions.all? { |condition| condition.match?(string) }
    end

    private

    def same_junction?(condition)
      condition.is_a?(And)
    end

    def operator_name
      'and'
    end

    def empty_is_always?
      true
    end

    def contains_always?(conditions)
      false
    end
  end

  class Or < Condition
    include Junction

    def simplify
      return Condition.always(source_range) if conditions.empty?
      return conditions.first if conditions.length == 1
      super
    end

    def match?(string)
      conditions.any? { |condition| condition.match?(string) }
    end

    private

    def same_junction?(condition)
      condition.is_a?(Or)
    end

    def operator_name
      'or'
    end

    def empty_is_always?
      false
    end

    def contains_always?(conditions)
      conditions.any?(&:always?)
    end
  end

  DEFAULT_MIN_LITERAL_LENGTH = 1
  DEFAULT_MAX_COMPLEXITY = 100

  def self.of(pattern, syntax = nil, options: nil,
              min_literal_length: DEFAULT_MIN_LITERAL_LENGTH,
              max_complexity: DEFAULT_MAX_COMPLEXITY)
    expression = pattern.is_a?(Regexp::Expression::Base) ? pattern :
      Regexp::Parser.parse(pattern, syntax, options: options)

    Builder.new(
      min_literal_length: min_literal_length,
      max_complexity: max_complexity
    ).build(expression)
  end

  class Builder
    def initialize(min_literal_length:, max_complexity:)
      @min_literal_length = min_literal_length
      @max_complexity = max_complexity
    end

    def build(expression)
      condition = analyze(expression)
      condition = simplify(condition)
      condition = remove_short_literals(condition)
      condition.complexity <= @max_complexity ? condition :
        Condition.always(source_range(expression))
    end

    private

    def always(expression)
      Condition.always(source_range(expression))
    end

    def analyze(expression)
      condition = analyze_without_quantifier(expression)
      condition = condition.simplify
      apply_quantifier(expression, condition)
    end

    def analyze_without_quantifier(expression)
      case expression
      when Regexp::Expression::Root
        analyze_sequence(expression)
      when Regexp::Expression::Group::Options
        analyze_sequence(expression)
      when Regexp::Expression::Group::Base
        analyze_group(expression)
      when Regexp::Expression::Alternation
        analyze_alternation(expression)
      when Regexp::Expression::Literal
        literal_condition(expression, literal_text(expression))
      when Regexp::Expression::EscapeSequence::CodepointList
        literal_condition(expression, expression.chars.join)
      when Regexp::Expression::EscapeSequence::Base
        analyze_escape_sequence(expression)
      when Regexp::Expression::Anchor::Base,
           Regexp::Expression::FreeSpace,
           Regexp::Expression::Keep::Mark
        always(expression)
      else
        always(expression)
      end
    end

    def analyze_group(expression)
      case expression
      when Regexp::Expression::Assertion::NegativeLookahead,
           Regexp::Expression::Assertion::NegativeLookbehind,
           Regexp::Expression::Group::Absence
        always(expression)
      when Regexp::Expression::Assertion::Base,
           Regexp::Expression::Group::Atomic,
           Regexp::Expression::Group::Capture,
           Regexp::Expression::Group::Named,
           Regexp::Expression::Group::Passive
        analyze_sequence(expression)
      else
        always(expression)
      end
    end

    def analyze_escape_sequence(expression)
      case expression
      when Regexp::Expression::EscapeSequence::AsciiEscape,
           Regexp::Expression::EscapeSequence::Backspace,
           Regexp::Expression::EscapeSequence::Bell,
           Regexp::Expression::EscapeSequence::FormFeed,
           Regexp::Expression::EscapeSequence::Newline,
           Regexp::Expression::EscapeSequence::Return,
           Regexp::Expression::EscapeSequence::Tab,
           Regexp::Expression::EscapeSequence::VerticalTab,
           Regexp::Expression::EscapeSequence::Hex,
           Regexp::Expression::EscapeSequence::Codepoint,
           Regexp::Expression::EscapeSequence::Octal,
           Regexp::Expression::EscapeSequence::UTF8Hex,
           Regexp::Expression::EscapeSequence::Literal
        literal_condition(expression, escape_literal(expression))
      else
        always(expression)
      end
    end

    def analyze_sequence(expression)
      blocks = []
      current = []

      expression.reject(&:decorative?).each do |child|
        condition = analyze(child)

        if transparent_zero_width_expression?(child)
          # Zero-width anchors and negative assertions do not consume text.
        elsif child.is_a?(Regexp::Expression::Assertion::Base)
          append_literal_block(blocks, current)
          current = []
          blocks << condition unless condition.always?
        elsif fixed_width_expression?(child)
          if condition.literal?
            current << condition
          else
            append_literal_block(blocks, current)
            current = []
            blocks << condition unless condition.always?
          end
        else
          append_literal_block(blocks, current)
          current = []
          blocks << condition unless condition.always?
        end
      end

      append_literal_block(blocks, current)
      Condition.and(blocks, source_range(expression))
    end

    def analyze_alternation(expression)
      Condition.or(
        expression.alternatives.map { |alternative| analyze_sequence(alternative) },
        source_range(expression)
      )
    end

    def literal_condition(expression, value)
      value = value.dup

      if value.empty?
        always(expression)
      elsif expression.case_insensitive? && !casefold_literal_supported?(value)
        always(expression)
      else
        Literal.new(
          value,
          source_range(expression),
          ignorecase: expression.case_insensitive?
        )
      end
    end

    def casefold_literal_supported?(value)
      value.length == 1 &&
        (value.ascii_only? || String.method_defined?(:casecmp?))
    end

    def literal_text(expression)
      expression.text.dup.force_encoding(Encoding::UTF_8)
    end

    def escape_literal(expression)
      return expression.char unless expression.is_a?(
        Regexp::Expression::EscapeSequence::Hex
      ) || expression.is_a?(Regexp::Expression::EscapeSequence::Octal)

      codepoint = expression.codepoint
      return expression.char if codepoint < 128
      return expression.char if codepoint > 255

      # A high byte remains one byte in a BINARY-encoded regexp. Treating it
      # as a UTF-8 character would reject matching ASCII-8BIT strings.
      [codepoint].pack('C')
    end

    def apply_quantifier(expression, condition)
      return condition unless expression.quantified?
      return Condition.always(source_range(expression)) if negative_limited_expression?(expression)
      return Condition.always(source_range(expression)) if expression_can_be_empty?(expression)

      quantifier = expression.quantifier
      fixed = quantifier.max >= 0 && quantifier.min == quantifier.max

      if fixed && quantifier.min == 1
        condition
      elsif fixed && condition.literal?
        repeated = Literal.new(
          condition.literal * quantifier.min,
          quantified_source_range(expression),
          ignorecase: condition.ignorecase
        )
        repeated
      else
        condition
      end
    end

    def expression_can_be_empty?(expression)
      return true if expression.quantified? && expression.quantifier.min == 0

      case expression
      when Regexp::Expression::Root,
           Regexp::Expression::Group::Options,
           Regexp::Expression::Group::Atomic,
           Regexp::Expression::Group::Capture,
           Regexp::Expression::Group::Named,
           Regexp::Expression::Group::Passive
        expression.reject(&:decorative?).all? { |child| expression_can_be_empty?(child) }
      when Regexp::Expression::Alternation
        expression.alternatives.any? do |alternative|
          alternative.reject(&:decorative?).all? { |child| expression_can_be_empty?(child) }
        end
      when Regexp::Expression::Anchor::Base,
           Regexp::Expression::FreeSpace,
           Regexp::Expression::Keep::Mark,
           Regexp::Expression::Assertion::Base
        true
      else
        false
      end
    end

    def negative_limited_expression?(expression)
      expression.is_a?(Regexp::Expression::Assertion::NegativeLookahead) ||
        expression.is_a?(Regexp::Expression::Assertion::NegativeLookbehind) ||
        expression.is_a?(Regexp::Expression::Group::Absence)
    end

    def simplify(condition)
      condition.simplify
    end

    def remove_short_literals(condition)
      case condition
      when Literal
        condition.complexity >= @min_literal_length ? condition : Condition.always(condition.source_range)
      when And
        kept = condition.conditions.map { |child| remove_short_literals(child) }.reject(&:always?)
        Condition.and(kept, condition.source_range).simplify
      when Or
        children = condition.conditions.map { |child| remove_short_literals(child) }
        return Condition.always(condition.source_range) if children.any?(&:always?)

        Condition.or(children, condition.source_range).simplify
      else
        condition
      end
    end

    def source_range(expression)
      [expression.ts, expression.te]
    end

    def quantified_source_range(expression)
      [expression.ts, expression.ends_at]
    end

    def transparent_zero_width_expression?(expression)
      expression.is_a?(Regexp::Expression::Anchor::Base) ||
        expression.is_a?(Regexp::Expression::FreeSpace) ||
        expression.is_a?(Regexp::Expression::Keep::Mark) ||
        expression.is_a?(Regexp::Expression::Assertion::NegativeLookahead) ||
        expression.is_a?(Regexp::Expression::Assertion::NegativeLookbehind)
    end

    def fixed_width_expression?(expression)
      return true if expression.is_a?(Regexp::Expression::Literal) ||
                    expression.is_a?(Regexp::Expression::EscapeSequence::Base)

      repetitions = expression.repetitions
      return false unless repetitions.min == repetitions.max

      match_length = expression.match_length
      match_length.fixed?
    rescue StandardError
      false
    end

    def append_literal_block(blocks, literals)
      return if literals.empty?

      merged = literals.inject do |left, right|
        merge_literal_conditions(left, right) || break
      end

      blocks << (merged || Condition.and(literals))
    end

    def merge_literal_conditions(left, right)
      return unless left.literal? && right.literal?
      return unless left.ignorecase == right.ignorecase
      return unless left.literal.encoding == right.literal.encoding

      Literal.new(
        left.literal + right.literal,
        merge_source_ranges(left.source_range, right.source_range),
        ignorecase: left.ignorecase
      )
    end

    def merge_source_ranges(left, right)
      return left || right unless left && right

      [[left.first, right.first].min, [left.last, right.last].max]
    end
  end
end
