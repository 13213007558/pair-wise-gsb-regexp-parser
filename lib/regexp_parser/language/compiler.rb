# frozen_string_literal: true

class Regexp::Parser::Language
  # Translates a parsed regexp into an epsilon-NFA with assertion edges,
  # then performs length-bounded subset construction (DFA) over it.
  #
  # Counting distinct strings on the DFA makes the result independent of
  # how many syntactic paths produce the same string (e.g. /a|a/).
  class Compiler
    DIGITS  = ('0'..'9').to_a.freeze
    HEX     = (DIGITS + ('a'..'f').to_a + ('A'..'F').to_a).freeze
    WORD    = (DIGITS + ('a'..'z').to_a + ('A'..'Z').to_a + ['_']).freeze
    # ASCII whitespace as recognized by \s. \v (0x0B) is included.
    SPACE   = ["\\t", "\\n", "\\v", "\\f", "\\r", " "].freeze
    # Candidate limit for automatically inferred alphabets. Larger finite
    # domains require an explicit alphabet to stay predictable.
    DOMAIN_LIMIT = 10_000

    ASSERTION_TOKENS = Regexp::Syntax::Token::Anchor::All
    LOOKAROUND_TOKENS = Regexp::Syntax::Token::Assertion::All
    EMPTY_EDGES = [].freeze

    def initialize(tree, global_options, alphabet, budget)
      @tree = tree
      @global_options = global_options
      @budget = budget
      @alphabet = normalize_alphabet(alphabet)
      @next_node = 0
      @nodes = {}
      @end_nodes = {}
      @impossible = false
      @anchor_impossible = false
      @end_mode = false
      @alphabet_prepared = false
    end

    attr_reader :alphabet
    attr_reader :resolved_alphabet

    def self.prepare(tree, global_options, alphabet, budget)
      compiler = new(tree, global_options, alphabet, budget)
      compiler.send(:validate!)
      compiler.send(:prepare_alphabet!)
      compiler
    end

    def build(max_length)
      validate!
      @anchor_impossible = eos_makes_language_empty?
      prepare_alphabet!

      @max_length = max_length
      if @anchor_impossible
        @start = new_node
        @accept = new_node
        @final = new_node
        freeze_automaton
        return self
      end
      @accept = new_node
      @final = new_node
      @start = new_node
      compile_expression(@tree, @start, @accept)
      # EOS edges point at @final; make that node equivalent to the normal
      # accept for the validated language.
      add_edge(@final, [:eps, nil, @accept])
      freeze_automaton
      self
    end

    def prepare_alphabet!
      return @alphabet if @alphabet_prepared

      if @alphabet.nil?
        inferred = infer_alphabet
        if inferred.nil?
          raise Regexp::Parser::InfiniteAlphabetError,
                'the regexp contains an unbounded character class; ' \
                'pass an explicit finite alphabet to Language.new'
        end
        if inferred.length > DOMAIN_LIMIT
          raise Regexp::Parser::InfiniteAlphabetError,
                "inferred alphabet has #{inferred.length} characters, " \
                "which exceeds the limit of #{DOMAIN_LIMIT}; " \
                'pass an explicit finite alphabet'
        end
        @alphabet = inferred.sort.uniq
      end
      @alphabet_prepared = true
      @alphabet
    end

    private

    # -- alphabet handling ------------------------------------------------

    def normalize_alphabet(alphabet)
      return nil if alphabet.nil?

      chars =
        case alphabet
        when String
          alphabet.chars
        when Array
          alphabet
        else
          raise Regexp::Parser::LanguageArgumentError,
                "alphabet must be a String or an Array, got #{alphabet.class}"
        end
      chars.each do |char|
        unless char.is_a?(String) && char.length == 1
          raise Regexp::Parser::LanguageArgumentError,
                "alphabet entries must be single characters, got #{char.inspect}"
        end
      end
      sorted = chars.uniq.sort
      raise Regexp::Parser::LanguageArgumentError, 'alphabet must not be empty' if sorted.empty?

      sorted
    end

    # Walks the AST and raises for features that cannot describe a finite
    # language without backreferences or recursion.
    def validate!
      each_expression(@tree) do |exp|
        case exp.type
        when :backref
          if Regexp::Syntax::Token::Backreference::RecursionLevel.include?(exp.token) ||
             Regexp::Syntax::Token::SubexpressionCall::All.include?(exp.token)
            unsupported!(exp, 'recursion and subexpression calls')
          else
            unsupported!(exp, 'backreferences')
          end
        when :assertion
          unsupported!(exp, 'lookarounds')
        when :conditional
          unsupported!(exp, 'conditionals')
        end

        case exp
        when Regexp::Expression::Group::Absence
          unsupported!(exp, 'absence groups ((?~...))')
        when Regexp::Expression::Keep::Mark
          unsupported!(exp, '\K')
        when Regexp::Expression::CharacterType::Linebreak
          unsupported!(exp, 'multi-character linebreaks (\R)')
        when Regexp::Expression::CharacterType::ExtendedGrapheme
          unsupported!(exp, 'grapheme clusters (\X)')
        end
      end
    end

    def unsupported!(exp, what)
      raise Regexp::Parser::UnsupportedFeatureError,
            "#{what} are not supported by the finite language interface " \
            "(at #{exp.to_s(:base).inspect})"
    end

    def eos_makes_language_empty?
      eos_anchors = []
      each_expression(@tree) do |exp|
        eos_anchors << exp if eos_anchor?(exp)
      end
      return false if eos_anchors.empty?

      eos_anchors.none? do |anchor|
        suffix_nullable?(anchor) || skippable_ancestor?(anchor)
      end
    end

    def skippable_ancestor?(anchor)
      ancestor_chain(anchor).any? do |exp|
        exp.respond_to?(:quantified?) && exp.quantified? && exp.quantifier.min.zero?
      end
    end

    def prefix_can_reach_eos?(anchor)
      chain = ancestor_chain(anchor)
      chain.each_cons(2).all? do |parent, child|
        case parent
        when Regexp::Expression::Alternation
          true
        when Regexp::Expression::Subexpression
          expressions = parent.expressions
          alternation = expressions.find { |exp| exp.is_a?(Regexp::Expression::Alternation) }
          if alternation
            branch = alternation.expressions.find do |alternative|
              alternative.expressions.include?(child) ||
                contains_descendant?(alternative, child)
            end
            branch.nil? || sequence_nullable_before?(branch.expressions, child)
          else
            sequence_nullable_before?(expressions, child)
          end
        else
          true
        end
      end
    end

    def contains_descendant?(container, target)
      return true if container == target
      return false unless container.respond_to?(:expressions)

      container.expressions.any? { |child| contains_descendant?(child, target) }
    end

    def sequence_nullable_before?(expressions, target)
      index = expressions.index(target)
      index = expressions.index { |exp| contains_descendant?(exp, target) } if index.nil?
      return true if index.nil?

      expressions[0...index].all? { |exp| expression_nullable?(exp) }
    end

    # Whole-string anchor semantics: \A/^/\G can only appear where everything
    # before them can be empty, and \z/$/\Z can only appear where everything
    # after them can be empty. Otherwise no full-string match is possible.
    def anchor_positions_valid?
      each_expression(@tree) do |exp|
        next unless exp.is_a?(Regexp::Expression::Anchor::Base)

        case exp.token
        when :bos, :bol, :match_start
          # BOS assertions are handled by start-gap closure, so a BOS in
          # one non-empty branch simply disables that branch.
          true
        when :eos, :eos_ob_eol, :eol
          # EOS branches are pruned during subset construction.
          true
        end
      end
      true
    end

    def prefix_nullable?(anchor)
      nullable_sequence_before?(anchor)
    end

    def suffix_nullable?(anchor)
      nullable_sequence_after?(anchor)
    end

    def nullable_sequence_before?(target)
      chain = ancestor_chain(target)
      chain.each_cons(2).all? { |parent, child| nullable_other_branches_before?(parent, child) }
    end

    def nullable_sequence_after?(target)
      chain = ancestor_chain(target)
      chain.each_cons(2).all? { |parent, child| nullable_other_branches_after?(parent, child) }
    end

    def ancestor_chain(target)
      chain = []
      current = target
      while current
        chain.unshift(current)
        current = current.respond_to?(:parent) ? current.parent : nil
      end
      chain
    end

    def nullable_other_branches_before?(parent, child)
      case parent
      when Regexp::Expression::Subexpression
        expressions = relevant_expressions(parent)
        index = expressions.index(child)
        return true if index.nil?

        expressions[0...index].all? { |exp| expression_nullable?(exp) }
      else
        true
      end
    end

    def nullable_other_branches_after?(parent, child)
      case parent
      when Regexp::Expression::Subexpression
        expressions = relevant_expressions(parent)
        index = expressions.index(child)
        return true if index.nil?

        expressions[(index + 1)..-1].all? { |exp| expression_nullable?(exp) }
      else
        true
      end
    end

    def relevant_expressions(parent)
      if parent.expressions.length == 1 &&
         parent.expressions[0].is_a?(Regexp::Expression::Alternation)
        [parent.expressions[0]]
      else
        parent.expressions
      end
    end

    def expression_nullable?(exp)
      case exp
      when Regexp::Expression::Anchor::Base, Regexp::Expression::FreeSpace
        true
      when Regexp::Expression::CharacterSet
        exp.quantified? && exp.quantifier.min.zero?
      when Regexp::Expression::Alternation
        exp.expressions.any? { |branch| sequence_nullable?(branch.expressions) }
      when Regexp::Expression::Subexpression
        return true if exp.quantified? && exp.quantifier.min.zero?

        sequence_nullable?(flatten_expressions(exp.expressions))
      else
        exp.respond_to?(:quantified?) && exp.quantified? && exp.quantifier.min.zero?
      end
    end

    def sequence_nullable?(expressions)
      expressions.all? { |exp| expression_nullable?(exp) }
    end

    def flatten_expressions(expressions)
      result = []
      expressions.each do |exp|
        if exp.is_a?(Regexp::Expression::Alternation)
          result << exp
        elsif exp.respond_to?(:expressions)
          result.concat(flatten_expressions(exp.expressions))
        else
          result << exp
        end
      end
      result
    end

    # Returns a finite sorted candidate alphabet inferred from the closed
    # character classes used by the regexp, or nil when an open class is
    # encountered.
    def infer_alphabet
      candidates = []
      each_expression(@tree) do |exp|
        next if exp.is_a?(Regexp::Expression::CharacterSet) && !exp.negative? &&
                exp.expressions.any?
        next if exp.is_a?(Regexp::Expression::Subexpression) &&
                !exp.is_a?(Regexp::Expression::CharacterSet)

        domain = closed_domain(exp)
        return nil if domain.nil?
        candidates.concat(domain)
      end
      candidates.sort.uniq
    end

    def container?(exp)
      case exp
      when Regexp::Expression::CharacterSet
        true
      when Regexp::Expression::Subexpression
        true
      else
        false
      end
    end

    # Finite candidate set for a leaf, nil if the leaf is open. Anchors,
    # free space and comments contribute no characters.
    def closed_domain(exp)
      case exp
      when Regexp::Expression::Anchor::Base,
           Regexp::Expression::FreeSpace,
           Regexp::Expression::Group::Comment
        []
      when Regexp::Expression::Literal
        if exp.set_level > 0 && exp.parent.is_a?(Regexp::Expression::CharacterSet::Range)
          # Range endpoints are handled by the range expansion below.
          []
        else
          literal_chars(exp)
        end
      when Regexp::Expression::EscapeSequence::Octal,
           Regexp::Expression::EscapeSequence::Hex,
           Regexp::Expression::EscapeSequence::Codepoint,
           Regexp::Expression::EscapeSequence::CodepointList
        decode_escape(exp).chars
      when Regexp::Expression::EscapeSequence::AsciiEscape  then ["\\e"]
      when Regexp::Expression::EscapeSequence::Bell        then ["\\a"]
      when Regexp::Expression::EscapeSequence::Backspace   then ["\\b"]
      when Regexp::Expression::EscapeSequence::FormFeed    then ["\\f"]
      when Regexp::Expression::EscapeSequence::Newline     then ["\\n"]
      when Regexp::Expression::EscapeSequence::Return      then ["\\r"]
      when Regexp::Expression::EscapeSequence::Tab         then ["\\t"]
      when Regexp::Expression::EscapeSequence::VerticalTab then ["\\v"]
      when Regexp::Expression::EscapeSequence::Literal     then [exp.text[-1]]
      when Regexp::Expression::EscapeSequence::AbstractMetaControlSequence
        nil
      when Regexp::Expression::CharacterType
        type_domain(exp)
      when Regexp::Expression::PosixClass
        posix_domain(exp)
      when Regexp::Expression::UnicodeProperty::Base
        nil
      when Regexp::Expression::CharacterSet::Range
        range_domain(exp)
      when Regexp::Expression::CharacterSet
        # A standalone set (not a range endpoint): inspect its members.
        set_domain(exp)
      else
        # Unknown terminal: do not guess, require an explicit alphabet.
        nil
      end
    end

    def type_domain(exp)
      case exp.token
      when :digit    then DIGITS
      when :nondigit then nil
      when :hex      then HEX
      when :nonhex   then nil
      when :word     then WORD
      when :nonword  then nil
      when :space    then SPACE
      when :nonspace then nil
      end
    end

    def posix_domain(exp)
      return nil if exp.negative?

      case exp.token
      when :digit   then DIGITS
      when :xdigit  then HEX
      when :alnum   then DIGITS + ('a'..'z').to_a + ('A'..'Z').to_a
      when :alpha   then ('a'..'z').to_a + ('A'..'Z').to_a
      when :upper   then ('A'..'Z').to_a
      when :lower   then ('a'..'z').to_a
      when :cntrl   then (0..31).map(&:chr) + [127.chr]
      when :blank   then [" ", "\\t"]
      when :space   then SPACE
      when :print   then (32..126).map(&:chr)
      when :graph   then (33..126).map(&:chr)
      when :punct   then punct_chars
      else nil
      end
    end

    def punct_chars
      (33..126).map(&:chr).reject { |char| WORD.include?(char) }
    end

    def range_domain(range)
      from = range.expressions[0]
      to = range.expressions[1]
      first = literal_endpoint(from)
      last = literal_endpoint(to)
      return nil if first.nil? || last.nil? || first.ord > last.ord
      return nil if (last.ord - first.ord) > DOMAIN_LIMIT

      (first.ord..last.ord).map { |codepoint| codepoint.chr }
    end

    def literal_endpoint(exp)
      case exp
      when Regexp::Expression::Literal
        chars = literal_chars(exp)
        chars.length == 1 ? chars[0] : nil
      when Regexp::Expression::EscapeSequence::Hex,
           Regexp::Expression::EscapeSequence::Octal,
           Regexp::Expression::EscapeSequence::Codepoint
        decoded = decode_escape(exp)
        decoded.length == 1 ? decoded : nil
      else
        nil
      end
    end

    def set_domain(set)
      return nil if set.negative?

      domain = []
      collect_set_domain(set, domain)
      domain
    end

    def collect_set_domain(exp, domain)
      case exp
      when Regexp::Expression::CharacterSet::Range
        member = range_domain(exp)
      when Regexp::Expression::CharacterSet
        if exp.negative?
          member = nil
        elsif exp.expressions.any? { |child| child.is_a?(Regexp::Expression::CharacterSet::Intersection) }
          member = intersection_domain(exp)
        else
          member = nil
          exp.expressions.each { |child| collect_set_domain(child, domain) }
        end
      when Regexp::Expression::CharacterSet::Intersection
        member = nil
        exp.expressions.each { |child| collect_set_domain(child, domain) }
      when Regexp::Expression::CharacterSet::IntersectedSequence
        member = nil
        exp.expressions.each { |child| collect_set_domain(child, domain) }
      else
        member = closed_domain(exp)
      end
      domain.concat(member) unless member.nil?
    end

    def intersection_domain(set)
      intersection = set.expressions.find do |child|
        child.is_a?(Regexp::Expression::CharacterSet::Intersection)
      end
      return nil if intersection.nil?

      factors = intersection.expressions.map do |sequence|
        factor = []
        sequence.expressions.each { |child| collect_set_domain(child, factor) }
        factor
      end
      # If any factor is open, the whole intersection is open for inference.
      return nil if factors.any?(&:nil?)

      factors.inject(nil) do |memo, factor|
        memo.nil? ? factor : memo & factor
      end
    end

    # -- AST helpers -------------------------------------------------------

    def each_expression(exp, &block)
      yield exp
      return unless exp.respond_to?(:expressions)

      exp.expressions.each { |child| each_expression(child, &block) }
    end

    def literal_chars(exp)
      decode_literal_text(exp.text, exp)
    end

    # Decodes ineffectual escapes such as \j into the actual character.
    def decode_literal_text(text, _exp)
      result = []
      scan = text.dup
      until scan.empty?
        if scan.start_with?('\\') && scan.length >= 2
          result << scan[1]
          scan = scan[2..-1]
        else
          result << scan[0]
          scan = scan[1..-1]
        end
      end
      result
    end

    def decode_escape(exp)
      if exp.is_a?(Regexp::Expression::EscapeSequence::CodepointList)
        exp.chars.join
      else
        exp.char
      end
    end

    # -- NFA construction --------------------------------------------------

    def freeze_automaton
      @nodes.each_value(&:freeze)
      @nodes.freeze
    end

    def new_node
      id = @next_node
      @next_node += 1
      @nodes[id] = []
      @end_nodes[id] = true if @end_mode
      id
    end

    def add_edge(from, edge)
      @nodes[from] << edge
      charge!
    end

    def charge!
      @budget.charge!
    end

    # Edges are [kind, data, target].
    #   [:char, char, target]
    #   [:eps, nil, target]
    #   [:bos, nil, target] beginning of string (\A, ^ under our semantics)
    #   [:eos, nil, target] end of string (\z, $, \Z under our semantics)
    #   [:wb, nil, target] word boundary (\b)
    #   [:nwb, nil, target] no word boundary (\B)
    def compile_sequence(expressions, from, to)
      current = from
      expressions.each_with_index do |exp, index|
        if eos_anchor?(exp)
          eos_entry = new_node
          eos_after = new_node
          @end_nodes[eos_after] = true
          @end_nodes[@final] = true
          add_edge(current, [:eps, nil, eos_entry])
          add_edge(eos_entry, [:eos, nil, eos_after])
          suffix = expressions[(index + 1)..-1] || []
          with_end_mode { compile_sequence(suffix, eos_after, @final) }
          return
        elsif index == expressions.length - 1
          compile_expression(exp, current, to)
        else
          junction = new_node
          compile_expression(exp, current, junction)
          current = junction
        end
      end
      add_edge(current, [:eps, nil, to]) if expressions.empty?
    end

    def eos_anchor?(exp)
      exp.is_a?(Regexp::Expression::Anchor::Base) &&
        [:eos, :eos_ob_eol, :eol].include?(exp.token)
    end

    def contains_eos_anchor?(exp)
      return true if eos_anchor?(exp)
      return false unless exp.respond_to?(:expressions)

      exp.expressions.any? { |child| contains_eos_anchor?(child) }
    end

    def with_end_mode
      previous = @end_mode
      @end_mode = true
      yield
    ensure
      @end_mode = previous
    end

    def compile_expression(exp, from, to)
      case exp
      when Regexp::Expression::Root
        compile_sequence(exp.expressions, from, to)
      when Regexp::Expression::Alternation
        compile_alternation(exp, from, to)
      when Regexp::Expression::SequenceOperation
        compile_alternation(exp, from, to)
      when Regexp::Expression::Group::Comment
        # nothing
      when Regexp::Expression::FreeSpace
        # ignored whitespace under free-spacing mode
      when Regexp::Expression::Anchor::Base
        compile_anchor(exp, from, to)
      when Regexp::Expression::CharacterSet
        if exp.quantified?
          compile_quantified_leaf(exp, from, to)
        else
          compile_atom_terminal(exp, from, to)
        end
      when Regexp::Expression::Subexpression
        if exp.quantified?
          compile_quantified_expression(exp, from, to)
        else
          # capture/passive/atomic/options groups are transparent
          compile_children(exp, from, to)
        end
      else
        if exp.quantified?
          compile_quantified_leaf(exp, from, to)
        else
          compile_unquantified_leaf(exp, from, to)
        end
      end
    end

    def compile_children(exp, from, to)
      compile_unquantified_children(exp.expressions, from, to)
    end

    def compile_unquantified_children(expressions, from, to)
      compile_sequence(expressions, from, to)
    end

    def compile_alternation(alternation, from, to)
      alternation.expressions.each do |branch|
        branch_start = new_node
        branch_end = new_node
        add_edge(from, [:eps, nil, branch_start])
        compile_sequence(branch.expressions, branch_start, branch_end)
        add_edge(branch_end, [:eps, nil, to])
      end
    end

    def branch_requires_eos?(branch)
      expressions_require_eos?(branch.expressions)
    end

    def expressions_require_eos?(expressions)
      expressions.any? do |child|
        child.is_a?(Regexp::Expression::Alternation) ?
          child.expressions.all? { |branch| branch_requires_eos?(branch) } :
          expression_requires_eos?(child)
      end
    end

    def expression_requires_eos?(exp)
      return true if eos_anchor?(exp)
      return false unless exp.respond_to?(:expressions)

      # A quantifier with min zero may be skipped, so it does not force EOS.
      return false if exp.quantified? && exp.quantifier.min.zero?

      expressions_require_eos?(exp.expressions)
    end

    def compile_anchor(exp, from, to)
      kind =
        case exp.token
        when :bos, :bol, :match_start then :bos
        when :eos, :eos_ob_eol, :eol
          add_edge(from, [:eos, nil, @final])
          return
        when :word_boundary          then :wb
        when :nonword_boundary       then :nwb
        end
      add_edge(from, [kind, nil, to])
    end

    def compile_quantified_leaf(exp, from, to)
      compile_quantifier(exp, from, to) { |f, t| compile_repetition_body(exp, f, t) }
    end

    def compile_quantified_expression(exp, from, to)
      compile_quantifier(exp, from, to) { |f, t| compile_unquantified_expression(exp, f, t) }
    end

    def compile_nullable_quantifier(exp, from, to)
      min = exp.quantifier.min
      body_min = minimum_body_length(exp)
      return if body_min.positive? && min.positive?

      add_edge(from, [:eps, nil, to])
    end

    def minimum_body_length(exp)
      if exp.is_a?(Regexp::Expression::CharacterSet)
        1
      elsif exp.is_a?(Regexp::Expression::Subexpression)
        expressions = exp.expressions
        alternation = expressions.find { |child| child.is_a?(Regexp::Expression::Alternation) }
        if alternation
          alternation.expressions.map { |branch| minimum_plain_sequence_length(branch.expressions) }.min
        else
          minimum_plain_sequence_length(expressions)
        end
      else
        position_families(exp).length
      end
    rescue Regexp::Parser::LanguageError
      1
    end

    def minimum_sequence_length(expressions)
      alternation = expressions.find do |child|
        child.is_a?(Regexp::Expression::Alternation)
      end
      return alternation.expressions.map { |branch| minimum_sequence_length(branch.expressions) }.min if alternation

      expressions.inject(0) { |sum, child| sum + minimum_expression_length(child) }
    end

    def minimum_plain_sequence_length(expressions)
      expressions.inject(0) { |sum, child| sum + minimum_plain_expression_length(child) }
    end

    def minimum_plain_expression_length(exp)
      case exp
      when Regexp::Expression::Anchor::Base, Regexp::Expression::FreeSpace
        0
      when Regexp::Expression::Alternation
        exp.expressions.map { |branch| minimum_plain_sequence_length(branch.expressions) }.min
      when Regexp::Expression::CharacterSet
        exp.quantified? ? exp.quantifier.min : 1
      when Regexp::Expression::Subexpression
        inner =
          if exp.expressions.length == 1 && exp.expressions[0].is_a?(Regexp::Expression::Alternation)
            minimum_plain_expression_length(exp.expressions[0])
          else
            minimum_plain_sequence_length(exp.expressions)
          end
        inner * (exp.quantified? ? exp.quantifier.min : 1)
      else
        (exp.quantified? ? exp.quantifier.min : 1)
      end
    end

    def minimum_expression_length(exp)
      case exp
      when Regexp::Expression::Anchor::Base, Regexp::Expression::FreeSpace
        0
      when Regexp::Expression::Alternation
        min_length = exp.expressions.map { |branch| minimum_sequence_length(branch.expressions) }.min
        min_length * (exp.quantified? ? exp.quantifier.min : 1)
      when Regexp::Expression::CharacterSet
        (exp.quantified? ? exp.quantifier.min : 1)
      when Regexp::Expression::Subexpression
        minimum_sequence_length(exp.expressions) * (exp.quantified? ? exp.quantifier.min : 1)
      else
        atom_min = exp.respond_to?(:expressions) ? minimum_sequence_length(exp.expressions) : 1
        atom_min * (exp.quantified? ? exp.quantifier.min : 1)
      end
    end

    def compile_unquantified_expression(exp, from, to)
      # Temporarily hide the outer quantifier so the body's children do not
      # inherit it. Children with their own quantifier are unaffected.
      quantifier = exp.quantifier
      exp.quantifier = nil
      begin
        compile_unquantified_children(exp.expressions, from, to)
      ensure
        exp.quantifier = quantifier
      end
    end

    def compile_unquantified_child(exp, from, to)
      case exp
      when Regexp::Expression::Anchor::Base
        compile_anchor(exp, from, to)
      when Regexp::Expression::CharacterSet
        compile_repetition_body(exp, from, to)
      when Regexp::Expression::Subexpression
        compile_unquantified_children(exp.expressions, from, to)
      when Regexp::Expression::Group::Comment, Regexp::Expression::FreeSpace
        # nothing
      else
        compile_repetition_body(exp, from, to)
      end
    end

    def compile_quantifier(exp, from, to)
      min = exp.quantifier.min
      max = exp.quantifier.max
      max = nil if max < 0
      return compile_nullable_quantifier(exp, from, to) if @end_mode
      body_min = minimum_body_length(exp)
      if body_min.zero?
        min = [min, @max_length].min
        max = [max, @max_length].min unless max.nil?
      else
        possible_min = [@max_length, 1_000_000].min / body_min
        return false if min > possible_min
        # Infinite repetitions stay as loops; only bounded intervals need
        # to be expanded.
        max = [max, possible_min].min unless max.nil?
      end

      current = from
      min.times do
        junction = new_node
        yield(current, junction)
        current = junction
      end

      if max.nil?
        loop_entry = new_node
        body_end = new_node
        loop_exit = new_node
        add_edge(current, [:eps, nil, loop_entry])
        add_edge(loop_entry, [:eps, nil, loop_exit])
        yield(loop_entry, body_end)
        add_edge(body_end, [:eps, nil, loop_entry])
        add_edge(loop_exit, [:eps, nil, to])
      else
        optional = max - min
        optional.times do
          next_node = new_node
          yield(current, next_node)
          add_edge(current, [:eps, nil, to])
          current = next_node
        end
        add_edge(current, [:eps, nil, to])
      end
      true
    end

    # One repetition of a quantified expression. Multi-character literals
    # and codepoint lists consume their full string in sequence.
    def compile_repetition_body(exp, from, to)
      if @end_mode
        # In end-only mode only zero-character paths survive. Quantified
        # atoms are handled by the caller; mandatory atoms vanish.
        return
      end
      families = position_families(exp)
      if families.empty? || families.any?(&:empty?)
        add_edge(from, [:eps, nil, to])
        return
      end

      compile_families(families, 0, from, to)
    end

    def compile_unquantified_leaf(exp, from, to)
      compile_repetition_body(exp, from, to)
    end

    def nullable_end_expression(exp, from, to)
      if exp.quantified? && exp.quantifier.min.zero?
        add_edge(from, [:eps, nil, to])
        return
      end

      case exp
      when Regexp::Expression::Anchor::Base
        compile_anchor(exp, from, to)
      when Regexp::Expression::FreeSpace
        add_edge(from, [:eps, nil, to])
      when Regexp::Expression::Alternation
        exp.expressions.each do |branch|
          branch_start = new_node
          branch_end = new_node
          add_edge(from, [:eps, nil, branch_start])
          contains_eos = branch.expressions.any? { |child| contains_eos_anchor?(child) }
          if @end_mode && !contains_eos
            # Only the branch that contains the EOS continuation survives
            # after crossing an end-of-string anchor.
          else
            compile_nullable_sequence(branch.expressions, branch_start, branch_end)
            add_edge(branch_end, [:eps, nil, to])
          end
        end
      when Regexp::Expression::Subexpression
        expressions = exp.expressions
        if expressions.length == 1 && expressions[0].is_a?(Regexp::Expression::Alternation)
          nullable_end_expression(expressions[0], from, to)
        else
          compile_nullable_sequence(expressions, from, to)
        end
      end
    end

    def compile_nullable_sequence(expressions, from, to)
      current = from
      expressions.each do |exp|
        if eos_anchor?(exp)
          add_edge(current, [:eos, nil, to])
          return
        end
        junction = new_node
        nullable_end_expression(exp, current, junction)
        current = junction
      end
      add_edge(current, [:eps, nil, to])
    end

    alias compile_atom_terminal compile_unquantified_leaf

    def compile_families(families, index, from, to)
      family = families[index]
      last = index == families.length - 1
      family.each do |char|
        if last
          add_edge(from, [:char, char, to])
        else
          junction = new_node
          add_edge(from, [:char, char, junction])
          compile_families(families, index + 1, junction, to)
        end
      end
    end

    # Each family contains the characters that one consumed position can
    # take. A literal with multiple characters contributes several families.
    def position_families(exp)
      case exp
      when Regexp::Expression::Literal
        exp.text.chars.map { |char| family_for_char(char, exp) }
      when Regexp::Expression::EscapeSequence::CodepointList
        decode_leaf(exp).chars.map { |char| family_for_char(char, exp) }
      when Regexp::Expression::EscapeSequence::Base
        [family_for_char(decode_leaf(exp), exp)]
      else
        members = membership_regexp(exp)
        [@alphabet.select { |char| members.match?('\A' + char + '\z') }]
      end
    end

    def family_for_char(char, exp)
      if ignore_case?(exp)
        @alphabet.select do |candidate|
          candidate.downcase == char.downcase || candidate.upcase == char.upcase ||
            candidate == char
        end.uniq
      else
        @alphabet.include?(char) ? [char] : []
      end
    end

    def decode_leaf(exp)
      decode_escape(exp)
    end

    # Builds a Ruby regexp for a single-position atom. Quantifier text is
    # excluded so the atom matches exactly once.
    def membership_regexp(exp)
      ::Regexp.new(exp.to_s(:base), membership_options(exp))
    rescue ::RegexpError => error
      raise Regexp::Parser::UnsupportedFeatureError,
            "cannot evaluate atom #{exp.to_s(:base).inspect}: #{error.message}"
    end

    def membership_options(exp)
      options = 0
      options |= ::Regexp::IGNORECASE if exp.options[:i] == true || @global_options & ::Regexp::IGNORECASE != 0
      options |= ::Regexp::MULTILINE if exp.options[:m] == true || @global_options & ::Regexp::MULTILINE != 0
      options
    end

    def ignore_case?(exp)
      exp.options[:i] == true || (@global_options & ::Regexp::IGNORECASE) != 0
    end

    # -- subset construction ----------------------------------------------

    def start_state
      entries = []
      start_entries.each do |node, requirement|
        expand_entry(node, :none, requirement).each do |gap_node, gap_requirement|
          entries << [gap_node, :none, gap_requirement]
        end
      end
      entries.uniq.sort_by { |node, prev_kind, requirement| [node, prev_rank(prev_kind), requirement_rank(requirement)] }
    end

    def prev_rank(prev_kind)
      case prev_kind
      when :none then 0
      when :nonword then 1
      when :word then 2
      else 3
      end
    end

    # Starting gap entries: epsilon, beginning-of-string and leading \B.
    # Leading \b would require a word character at the start boundary, so it
    # is handled as a character-edge requirement instead of a gap closure.
    def start_entries
      entries = []
      seen = {}
      stack = [[@start, nil]]
      until stack.empty?
        node, requirement = stack.pop
        key = [node, requirement]
        next if seen[key]

        seen[key] = true
        entries << key
        edges_for(node).each do |edge|
          kind = edge[0]
          case kind
          when :eps, :bos
            target = edge[2]
            stack << [target, requirement]
          end
        end
      end
      entries
    end

    # Closure usable at the start: plain epsilons and beginning-of-string
    # assertions.
    def start_gap(node)
      start_seen = { node => true }
      stack = [node]
      until stack.empty?
        current = stack.pop
        edges_for(current).each do |edge|
          next unless edge[0] == :eps || edge[0] == :bos

          target = edge[2]
          next if start_seen[target]

          start_seen[target] = true
          stack << target
        end
      end
      start_seen.keys
    end

    # Closure usable after consuming a character: plain epsilons only.
    def plain_gap(node)
      closure(node) { |edge| edge[0] == :eps }
    end

    def closure(start)
      seen = { start => true }
      stack = [start]
      until stack.empty?
        node = stack.pop
        edges_for(node).each do |edge|
          next unless yield(edge)
          target = edge[2]
          next if seen[target]

          seen[target] = true
          stack << target
        end
      end
      seen.keys
    end

    def edges_for(node)
      @nodes[node] || EMPTY_EDGES
    end

    def end_only_node?(node)
      @end_nodes[node] == true
    end

    # Expands a [node, prev_kind, requirement] entry through plain epsilon
    # edges and word-boundary assertions. Assertions become requirements
    # for the character edge that follows. Returns [node, requirement]
    # entries.
    def expand_entry(node, prev_kind, requirement)
      @pair_expansion_cache ||= {}
      key = [node, requirement]
      cached = @pair_expansion_cache[key]
      return cached if cached

      seen = { [node, requirement] => true }
      stack = [[node, requirement]]
      entries = []
      until stack.empty?
        current, current_requirement = stack.pop
        entries << [current, current_requirement]
        edges_for(current).each do |edge|
          kind = edge[0]
          case kind
          when :eps
            add_expansion_target(seen, stack, entries, edge[2], current_requirement)
          when :wb, :nwb
            merged = merge_requirements(current_requirement, kind)
            next if merged == :conflict

            add_expansion_target(seen, stack, entries, edge[2], merged)
          end
        end
      end
      result = entries.uniq.sort_by { |node, requirement| [node, requirement_rank(requirement)] }
      @pair_expansion_cache[key] = result
      result
    end

    def requirement_rank(requirement)
      case requirement
      when nil then 0
      when :wb then 1
      when :nwb then 2
      when :conflict then 3
      else 4
      end
    end

    def add_expansion_target(seen, stack, entries, node, requirement)
      key = [node, requirement]
      return if seen[key]

      seen[key] = true
      stack << [node, requirement]
      entries << [node, requirement]
    end

    def merge_requirements(first, second)
      return second if first.nil?
      return first if first == second

      :conflict
    end

    def resolve_requirements(requirements)
      return nil if requirements.empty?
      return nil if requirements.include?(:conflict)

      requirements.include?(:wb) && requirements.include?(:nwb) ? nil : requirements[0]
    end

    # One character transition of a DFA state.
    def transition(state, char)
      gaps = state
      targets = []
      gaps.each do |node, prev_kind, requirement|
        expand_entry(node, prev_kind, requirement).each do |gap_node, gap_requirement|
          next unless boundary_allows?(gap_requirement, prev_kind, char)

          edges_for(gap_node).each do |edge|
            next unless edge[0] == :char && edge[1] == char

            targets.concat(plain_gap(edge[2]))
          end
        end
      end
      return nil if targets.empty?

      next_kind = word_char?(char) ? :word : :nonword
      targets.uniq.sort.map { |target| [target, next_kind, nil] }.sort_by do |node, prev_kind, requirement|
        [node, prev_rank(prev_kind), requirement_rank(requirement)]
      end
    end

    def boundary_allows?(requirement, prev_kind, char)
      case requirement
      when nil  then true
      when :conflict then false
      when :wb
        boundary?(prev_kind, word_char?(char) ? :word : :nonword)
      when :nwb
        !boundary?(prev_kind, word_char?(char) ? :word : :nonword)
      end
    end

    def boundary?(left, right)
      if left == :none
        right == :word
      elsif right == :none
        left == :word
      else
        left != right
      end
    end

    def word_char?(char)
      WORD.include?(char)
    end

    # Acceptance of a DFA state after a complete string: trailing
    # end-of-string and word-boundary assertions must pass.
    def accepting?(state)
      state.any? do |node, prev_kind, requirement|
        acceptance_closure(node, prev_kind, requirement)
      end
    end

    def acceptance_closure(node, prev_kind, requirement = nil)
      @acceptance_cache ||= {}
      key = [node, prev_kind, requirement]
      return @acceptance_cache[key] if @acceptance_cache.key?(key)

      result = compute_acceptance(node, prev_kind, requirement)
      @acceptance_cache[key] = result
      result
    end

    def compute_acceptance(node, prev_kind, requirement)
      seen = { [node, prev_kind, requirement] => true }
      stack = [[node, prev_kind, requirement]]
      until stack.empty?
        current, current_prev_kind, requirement = stack.pop
        return true if (current == @accept || current == @final) &&
           trailing_requirement_ok?(requirement, current_prev_kind)

        edges_for(current).each do |edge|
          kind = edge[0]
          case kind
          when :eps
            target_key = [edge[2], current_prev_kind, requirement]
          when :eos
            next unless end_only_node?(edge[2]) || edge[2] == @final
            next unless trailing_requirement_ok?(requirement, current_prev_kind)

            target_key = [edge[2], current_prev_kind, requirement]
          when :wb, :nwb
            merged = merge_requirements(requirement, kind)
            next if merged == :conflict

            target_key = [edge[2], current_prev_kind, merged]
          else
            next
          end
          next if seen[target_key]

          seen[target_key] = true
          stack << target_key
        end
      end
      false
    end

    def plain_reaches_accept?(node)
      seen = { node => true }
      stack = [node]
      until stack.empty?
        current = stack.pop
        return true if current == @accept

        edges_for(current).each do |edge|
          next unless edge[0] == :eps
          target = edge[2]
          next if seen[target]

          seen[target] = true
          stack << target
        end
      end
      false
    end

    # At end of string the boundary is between the last consumed character
    # and the end of input: \b holds after a word character, \B otherwise.
    def trailing_requirement_ok?(requirement, prev_kind)
      case requirement
      when nil, :conflict then requirement.nil?
      when :wb then prev_kind == :word
      when :nwb then prev_kind != :word || prev_kind == :none
      end
    end

    # -- counting ----------------------------------------------------------

    # Counts accepting strings for every length 0..max_length from the
    # given DFA start state. Returns [counts, complete].
    def counts(max_length)
      counts = Array.new(max_length + 1) { 0 }
      start = start_state
      counts[0] = accepting?(start) ? 1 : 0

      layer = { start => 1 }
      max_length.times do |length|
        next_layer = Hash.new(0)
        layer.each do |state, multiplicity|
          @alphabet.each do |char|
            target = transition(state, char)
            @budget.charge!
            next if target.nil?

            next_layer[target] += multiplicity
          end
        end
        layer = next_layer
        accepted = 0
        layer.each do |state, multiplicity|
          accepted += multiplicity if accepting?(state)
        end
        counts[length + 1] = accepted
        unless @budget.alive?
          return [counts, false]
        end
      end
      [counts, true]
    end

    # Returns the string with the given zero-based rank among all strings
    # of exactly +length+ characters, in alphabetical order. Returns nil
    # when the budget is exhausted.
    def nth(length, rank)
      @state_count_memo = {}
      state = start_state
      return '' if length.zero? && accepting?(state)

      string = ''.dup
      remaining = length
      loop do
        if remaining.zero?
          return string if rank.zero? && accepting?(state)

          return nil
        end

        chosen = nil
        @alphabet.each do |char|
          target = transition(state, char)
          block_count = target.nil? ? 0 : count_from_state(target, remaining - 1)
          if rank < block_count
            chosen = [char, target]
            break
          end
          rank -= block_count
          @budget.charge!
        end
        return nil if chosen.nil?

        char, target = chosen
        string << char
        state = target
        remaining -= 1
        return nil unless @budget.alive?
      end
    end

    def count_from_state(state, remaining)
      @state_count_memo ||= {}
      key = [state, remaining]
      return @state_count_memo[key] if @state_count_memo.key?(key)

      value =
        if remaining.zero?
          accepting?(state) ? 1 : 0
        else
          @alphabet.inject(0) do |sum, char|
            target = transition(state, char)
            sum + (target.nil? ? 0 : count_from_state(target, remaining - 1))
          end
        end
      @state_count_memo[key] = value
    end

    # suffix[remaining][state] = number of strings of exactly +remaining+
    # characters that lead from +state+ to an accepting DFA state.
    def suffix_table(length)
      states = states_for_suffix(length)
      table = Array.new(length + 1) { Hash.new(0) }
      states.each { |state| table[0][state] = accepting?(state) ? 1 : 0 }

      (1..length).each do |remaining|
        states.each do |state|
          @alphabet.each do |char|
            target = transition(state, char)
            next if target.nil?

            table[remaining][state] += table[remaining - 1].fetch(target, 0)
          end
          @budget.charge!
          return nil unless @budget.alive?
        end
      end
      table
    end

    def states_for_suffix(length)
      states = { start_state => true }
      frontier = [start_state]
      length.times do
        next_frontier = []
        frontier.each do |state|
          @alphabet.each do |char|
            target = transition(state, char)
            next if target.nil?
            next if states[target]

            states[target] = true
            next_frontier << target
          end
        end
        frontier = next_frontier
      end
      states.keys
    end

    # Enumerates DFA states reachable in at most +max_length+ transitions.
    def reachable_states(max_length)
      states = { start_state => true }
      frontier = [start_state]
      max_length.times do
        next_frontier = []
        frontier.each do |state|
          @alphabet.each do |char|
            target = transition(state, char)
            next if target.nil?
            next if states[target]

            states[target] = true
            next_frontier << target
          end
        end
        frontier = next_frontier
      end
      states.keys
    end

    # DFA transition and accepting? are reused by unranking; expose the
    # needed pieces.
    public :counts, :nth, :transition, :accepting?, :start_state, :alphabet
  end
end
