# frozen_string_literal: true

class Regexp::Parser
  # Conservative literal-substring requirements for a regular expression.
  #
  # Every returned condition is a pre-filter: if it rejects a String, the
  # original Regexp cannot match that String. Unknown or potentially variable
  # syntax is represented by {Regexp::Parser::LiteralRequirement::Any},
  # which accepts every String.
  module LiteralRequirement
    # Accepts every String. Used when no safe literal requirement can be
    # derived from a regular expression or part of it.
    class Any
      def and(other)
        other
      end

      def or(_other)
        self
      end

      def match?(_string)
        true
      end
      alias_method :===, :match?

      def ==(other)
        other.is_a?(Any)
      end
      alias_method :eql?, :==

      def hash
        Any.hash
      end

      def inspect
        '#<Regexp::Parser::LiteralRequirement any>'
      end
    end

    # A literal String that must occur in every possible match's input.
    class Contains
      attr_reader :string, :casefold

      def initialize(string, casefold: false)
        @string = string.dup.freeze
        @casefold = !!casefold
        freeze
      end

      def and(other)
        return self if other.is_a?(Any)

        if other.is_a?(self.class) && casefold == other.casefold
          if casefold
            return self if /#{Regexp.escape(other.string)}/i.match?(string)
            return other if /#{Regexp.escape(string)}/i.match?(other.string)
          else
            return self if string.include?(other.string)
            return other if other.string.include?(string)
          end
        end

        And.new([self, other])
      end

      def or(other)
        return ANY if other.is_a?(Any)

        if other.is_a?(self.class) && casefold == other.casefold
          return self if string == other.string
        end

        Or.new([self, other])
      end

      def match?(input)
        return true if string.empty?

        if casefold
          casefold_match?(input)
        else
          literal = string
          if input.encoding == Encoding::BINARY && literal.encoding == Encoding::UTF_8
            literal = literal.dup.force_encoding(Encoding::BINARY)
          elsif !input.ascii_only? && !literal.ascii_only?
            return false if literal.encoding == Encoding::BINARY &&
                            input.encoding != Encoding::BINARY
            literal = literal.encode(input.encoding)
          elsif literal.encoding == Encoding::BINARY &&
                !literal.ascii_only? &&
                input.encoding != Encoding::BINARY
            return false
          end
          input.include?(literal)
        end
      rescue EncodingError
        # Different encodings can represent the same byte sequence. Checking
        # that narrower case is safe; all other incompatibilities are passed.
        return bytes_include?(input) if !casefold && string.ascii_only?

        true
      end
      alias_method :===, :match?

      def inspect
        "#<#{self.class.name} #{string.inspect}#{':i' if casefold}>"
      end

      def ==(other)
        other.is_a?(Contains) &&
          string == other.string &&
          casefold == other.casefold
      end
      alias_method :eql?, :==

      def hash
        [string, casefold].hash
      end

      private

      def casefold_match?(input)
        pattern = string.encode(input.encoding)
        /#{Regexp.escape(pattern)}/i.match?(input)
      rescue EncodingError, RegexpError
        string.encoding == Encoding::BINARY &&
          !string.ascii_only? &&
          input.encoding != Encoding::BINARY ? false : true
      end

      def bytes_include?(input)
        input.bytes.each_cons(string.bytesize).any? do |bytes|
          bytes == string.bytes
        end
      end
    end

    # Every child condition must hold.
    class And
      attr_reader :children

      def initialize(children)
        @children = children.flat_map do |child|
          child.is_a?(And) ? child.children : [child]
        end.reject { |child| child.is_a?(Any) }
           .reject { |child| child.is_a?(Or) && child.children.empty? }
           .uniq.freeze
        freeze
      end

      def and(other)
        And.new([self, other])
      end

      def or(other)
        return ANY if other.is_a?(Any)

        Or.new([self, other])
      end

      def match?(string)
        children.all? { |child| child.match?(string) }
      end
      alias_method :===, :match?

      def inspect
        "#<#{self.class.name} #{children.inspect}>"
      end

      def ==(other)
        other.is_a?(And) && children == other.children
      end
      alias_method :eql?, :==

      def hash
        children.hash
      end
    end

    # At least one child condition must hold.
    class Or
      attr_reader :children

      def initialize(children)
        @children = children.flat_map do |child|
          child.is_a?(Or) ? child.children : [child]
        end.reject { |child| child.is_a?(Any) }
           .reject { |child| child.is_a?(And) && child.children.empty? }
           .uniq.freeze
        freeze
      end

      def and(other)
        And.new([self, other])
      end

      def or(other)
        return ANY if other.is_a?(Any)

        Or.new([self, other])
      end

      def match?(string)
        children.empty? || children.any? { |child| child.match?(string) }
      end
      alias_method :===, :match?

      def inspect
        "#<#{self.class.name} #{children.inspect}>"
      end

      def ==(other)
        other.is_a?(Or) && children == other.children
      end
      alias_method :eql?, :==

      def hash
        children.hash
      end
    end

    All = And
    Either = Or

    ANY = Any.new

    # Returns a conservative pre-filter condition for a parsed or parseable
    # regular expression. See Regexp::Parser.literal_requirement.
    def self.for(input, syntax = nil, options: nil)
      binary_options = false
      fixed_options = false

      if input.is_a?(::Regexp)
        root = Regexp::Parser.parse(input, syntax)
        encoding = input.encoding
        binary_options = encoding == Encoding::BINARY
        fixed_options = encoding == Encoding::UTF_8
      elsif input.is_a?(Regexp::Expression::Root)
        root = input
        encoding = input.expressions.any? ? Encoding::UTF_8 : Encoding::US_ASCII
      else
        root = Regexp::Parser.parse(input, syntax, options: options)
        encoding = initial_encoding(input, options)
        binary_options = binary_options?(options)
        fixed_options = fixed_options?(options)
      end

      Analyzer.new(encoding, binary_options, fixed_options).analyze(root)
    end

    def self.initial_encoding(source, options)
      flags = options || 0
      return Encoding::UTF_8 if flags & ::Regexp::FIXEDENCODING != 0
      return Encoding::US_ASCII if flags & ::Regexp::NOENCODING != 0

      source.ascii_only? ? Encoding::US_ASCII : source.encoding
    end

    def self.binary_options?(options)
      (options || 0) & ::Regexp::NOENCODING != 0
    end

    def self.fixed_options?(options)
      (options || 0) & ::Regexp::FIXEDENCODING != 0
    end
    private_class_method :initial_encoding, :binary_options?, :fixed_options?

    # @api private
    class Analyzer
      include Regexp::Expression

      def initialize(encoding, binary_options = false, fixed_options = false)
        @encoding = encoding
        @binary_options = binary_options
        @fixed_options = fixed_options
      end

      def analyze(expression)
        expression_options(expression) do
          apply_quantifier(analyze_node(expression), expression)
        end
      end

      private

      def analyze_node(expression)
        case expression
        when Alternation
          expression.alternatives
                    .map { |alternative| analyze_sequence(alternative) }
                    .reduce { |condition, alternative| condition.or(alternative) } || ANY
        when Conditional::Expression
          analyze_conditional(expression)
        when Group::Comment
          ANY
        when Assertion::NegativeLookahead, Assertion::NegativeLookbehind, Group::Absence
          ANY
        when Assertion::Base
          analyze_sequence_expressions(expression.expressions)
        when CharacterSet
          analyze_set(expression)
        when Subexpression
          analyze_sequence_expressions(expression.expressions)
        when Literal
          literal(expression.text, expression.options[:i])
        when EscapeSequence::Base
          analyze_escape(expression)
        else
          ANY
        end
      end

      def analyze_sequence(expression)
        analyze_sequence_expressions(expression.expressions)
      end

      def analyze_sequence_expressions(expressions)
        conditions = []
        previous_literal = nil
        expressions.each_with_index do |child, index|
          condition = analyze(child)
          if foldable_literal_expression?(child) &&
               foldable_literal_expression?(previous_literal) &&
               mergeable_literal?(conditions.last, condition)
            merged = conditions.last.string + condition.string
            conditions[-1] = Contains.new(merged, casefold: condition.casefold)
            previous_literal = child
          else
            conditions << condition
            previous_literal = child if foldable_literal_expression?(child)
          end
        end

        conditions.reduce(ANY) { |requirement, condition| requirement.and(condition) }
      end

      def mergeable_literal?(previous_condition, condition)
        previous_condition.is_a?(Contains) &&
          condition.is_a?(Contains) &&
          previous_condition.casefold == condition.casefold &&
          previous_condition.string.encoding == condition.string.encoding
      end

      def foldable_literal_expression?(expression)
        return false if expression.nil?
        return false if expression.quantified?

        foldable = expression.is_a?(Literal) ||
          expression.is_a?(EscapeSequence::Base) ||
          expression.is_a?(Group::Passive) ||
          expression.is_a?(Group::Capture) ||
          expression.is_a?(Group::Atomic) ||
          expression.is_a?(Group::Options) && expression.token != :options_switch
        foldable
      end

      def analyze_conditional(expression)
        branches = expression.branches
        return ANY if branches.length < 2

        branches.map { |branch| analyze_sequence(branch) }
                .reduce { |condition, branch| condition.or(branch) }
      end

      def expression_options(expression)
        previous_encoding = @encoding
        apply_encoding_options(expression.options)
        yield
      ensure
        @encoding = previous_encoding
      end

      def apply_encoding_options(options)
        @encoding = Encoding::UTF_8 if options[:u]
        @encoding = Encoding::US_ASCII if options[:d]
        @encoding = Encoding::BINARY if options[:a]
      end

      def apply_quantifier(condition, expression)
        return condition unless expression.quantified?
        return ANY if expression.quantifier.min.to_i.zero?

        condition
      end

      def analyze_set(set)
        return ANY if set.negative

        conditions = set.expressions.map { |member| analyze_set_member(member) }
        return ANY if conditions.any? { |condition| condition.is_a?(Any) }

        conditions.reduce { |condition, member| condition.or(member) } || ANY
      end

      def analyze_set_member(member)
        case member
        when CharacterSet::Range
          ANY
        when CharacterSet::Intersection
          analyze_set_intersection(member)
        when Literal
          literal(member.text, member.options[:i])
        when EscapeSequence::Base
          analyze_escape(member)
        else
          ANY
        end
      end

      def analyze_set_intersection(intersection)
        conditions = intersection.expressions.map { |member| analyze_set_member(member) }
        return ANY if conditions.empty? || conditions.any? { |condition| condition.is_a?(Any) }

        conditions.reduce { |condition, member| condition.and(member) }
      end

      def analyze_escape(escape)
        value = escape_value(escape)
        return value if value.is_a?(Any)

        literal(value, escape.options[:i])
      end

      def escape_value(escape)
        case escape
        when EscapeSequence::CodepointList
          escape.codepoints.map { |codepoint| codepoint_char(codepoint) }.join
        when EscapeSequence::UTF8Hex
          bytes = escape.text.scan(/\h+/).map { |byte| Integer(byte, 16) }.pack('C*')
          if @binary_options
            @encoding = Encoding::BINARY
            bytes.force_encoding(Encoding::BINARY)
          else
            @encoding = Encoding::UTF_8
            bytes.force_encoding(Encoding::UTF_8)
          end
        when EscapeSequence::Literal
          encode(escape.text[1])
        when EscapeSequence::Hex, EscapeSequence::Octal,
             EscapeSequence::Control, EscapeSequence::Meta, EscapeSequence::MetaControl
          codepoint_char(escape.codepoint, true)
        else
          codepoint_char(escape.codepoint)
        end
      rescue ArgumentError, RangeError, EncodingError
        ANY
      end

      def codepoint_char(codepoint, binary_byte = false)
        return codepoint.chr(@encoding) if codepoint < 128
        return ANY if @fixed_options && binary_byte

        encoding =
          if binary_byte && !@fixed_options
            @binary_options ? Encoding::BINARY : Encoding::UTF_8
          elsif @encoding == Encoding::BINARY || @binary_options
            Encoding::BINARY
          else
            Encoding::UTF_8
          end

        @encoding = encoding
        codepoint.chr(encoding)
      end

      def literal(value, casefold = false)
        string = encode(value.to_s)
        return ANY if string.nil?
        return Contains.new('', casefold: casefold) if string.empty?

        Contains.new(string, casefold: casefold)
      end

      def encode(string)
        return string.dup.force_encoding(@encoding) if @encoding == Encoding::BINARY
        return string.dup.force_encoding(Encoding::US_ASCII) if @encoding == Encoding::US_ASCII

        string.encode(@encoding)
      rescue EncodingError
        nil
      end
    end
  end

  # Returns a condition describing literal substrings that every match of
  # +regexp+ must contain. The returned object responds to #match? and #===;
  # use it to cheaply reject input before running the original regular
  # expression.
  #
  #   requirement = Regexp::Parser.literal_requirement(/foo(?:bar|baz)/)
  #   requirement.match?('something foobar') # => true
  #   requirement.match?('nope')             # => false
  #
  # When no safe requirement can be derived, an unconditional condition is
  # returned. Regexp literals that occur only in optional parts, unmatched
  # alternatives, negative assertions, or other uncertain positions are not
  # treated as requirements.
  def self.literal_requirement(input, syntax = nil, options: nil)
    LiteralRequirement.for(input, syntax, options: options)
  end
end
