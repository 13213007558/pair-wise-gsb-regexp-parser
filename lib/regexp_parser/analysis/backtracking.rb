# frozen_string_literal: true

require_relative '../parser'

module RegexpParser
  # Static analysis of potential catastrophic backtracking ("ReDoS").
  #
  # The analyzer looks for an unbounded, backtrackable repetition whose body
  # is ambiguous on some repeated +unit+ and that is followed by a suffix that
  # cannot absorb an arbitrarily long run of that unit. Such a pattern admits
  # exponentially many ways of splitting a long run of the unit between
  # iterations of the repetition before the suffix inevitably fails.
  #
  # Results have one of three verdicts:
  #
  #   :risk          - a concrete witness was derived from the AST
  #   :no_risk_found - no provable witness; NOT a proof of safety
  #   :unanalyzable  - constructs were encountered that the analyzer does not
  #                    model (e.g. backreferences, lookarounds, recursion)
  #
  # A report can carry both a proven risk and limitations; :unanalyzable is
  # only returned when no risk could be proven, so it is never displayed as
  # "safe".
  class Backtracking
    VERDICTS = %i[risk no_risk_found unanalyzable].freeze

    # (type, token) pairs whose matching semantics this analyzer does not
    # model. A pair matches when both type and token are equal.
    LIMITATIONS = {
      [:backref, :number]       => 'numeric backreferences',
      [:backref, :name_ref]     => 'named backreferences',
      [:backref, :name]         => 'named backreferences',
      [:backref, :number_call]  => 'numeric subexpression calls',
      [:backref, :name_call]    => 'named subexpression calls',
      [:backref, :number_recursion]      => 'recursive subexpression calls',
      [:backref, :name_recursion]        => 'recursive subexpression calls',
      [:group, :absence]        => 'absence groups',
      [:keep, :mark]            => 'keep marks (\\K)',
      [:conditional, :open]     => 'conditionals',
    }.freeze

    ASSERTION_TOKENS = %i[
      lookahead nlookahead lookbehind nlookbehind
    ].freeze

    # Zero-width anchors that end a line/string and therefore make every
    # longer-than-consumed run of the pump unit fail at that position.
    TERMINATOR_ANCHORS = %i[eos eos_ob_eol eol bol].freeze

    Result = Struct.new(:verdict, :source, :findings, :limitations, keyword_init: true) do
      def risk?;          verdict == :risk;          end
      def no_risk_found?; verdict == :no_risk_found; end
      def unanalyzable?;  verdict == :unanalyzable;  end
    end

    Finding = Struct.new(
      :kind, :range, :expression_text, :unit, :witness, :reason,
      :verification, keyword_init: true
    ) do
      def to_h
        {
          kind:             kind,
          range:            range,
          starts_at:        range.first,
          ends_at:          range.last,
          expression_text:  expression_text,
          unit:             unit,
          witness:          witness,
          reason:           reason,
          verification:     verification,
        }
      end
    end

    Witness = Struct.new(
      :prefix, :pump, :suffix, :growth, :lengths,
      keyword_init: true
    ) do
      def inputs
        lengths.map { |n| prefix + pump * n + suffix }
      end

      def to_h
        {
          prefix:  prefix,
          pump:    pump,
          suffix:  suffix,
          growth:  growth,
          lengths: lengths,
        }
      end
    end

    Verification = Struct.new(:method, :timeout, :observations, :summary,
                              keyword_init: true)

    # Analyzes a pattern given as a Regexp, String, or parsed AST.
    def self.analyze(pattern, timeout: 0.1, pump_lengths: (12..24).step(2).to_a,
                     max_findings: 5, verify: true)
      new(timeout: timeout, pump_lengths: pump_lengths,
          max_findings: max_findings, verify: verify).analyze(pattern)
    end

    def initialize(timeout:, pump_lengths:, max_findings:, verify:)
      @timeout = timeout
      @pump_lengths = pump_lengths
      @max_findings = max_findings
      @verify = verify
    end

    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    def analyze(pattern)
      source, root, parse_error = parse(pattern)
      return unparsable(source, parse_error) unless root

      @source = source

      limitations = collect_limitations(root)
      findings = detect_findings(root)

      verdict = if findings.any?
                  :risk
                elsif limitations.any?
                  :unanalyzable
                else
                  :no_risk_found
                end

      Result.new(
        verdict:     verdict,
        source:      source,
        findings:    findings,
        limitations: limitations,
      )
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    private

    def parse(pattern)
      case pattern
      when Regexp::Expression::Root
        [pattern.to_s, pattern, nil]
      else
        root = Regexp::Parser.parse(pattern)
        [pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(pattern.to_s), root, nil]
      end
    rescue StandardError => e
      [pattern, nil, e]
    end

    def unparsable(source, error)
      Result.new(
        verdict:     :unanalyzable,
        source:      source,
        findings:    [],
        limitations: ["pattern could not be parsed: #{error.message}"],
      )
    end

    # -- limitation collection ---------------------------------------------

    def collect_limitations(root)
      limitations = []
      root.each_expression do |exp|
        if ASSERTION_TOKENS.include?(exp.token)
          limitations << limitation_note(exp, 'lookaround assertions')
        elsif (note = LIMITATIONS[[exp.type, exp.token]])
          limitations << limitation_note(exp, note)
        end
      end
      limitations.uniq
    end

    def limitation_note(exp, what)
      "#{what} at position #{exp.ts} are not modeled"
    end

    # -- finding detection --------------------------------------------------

    def detect_findings(root)
      findings = []
      each_unbounded_repetition(root) do |exp|
        break if findings.length >= @max_findings
        finding = analyze_repetition(exp)
        findings << finding if finding
      end
      findings
    end

    # Yields expressions carrying an unbounded quantifier that is not
    # possessive and that is not itself sealed inside an atomic group.
    def each_unbounded_repetition(root)
      root.each_expression do |exp|
        next unless eligible_repetition?(exp)
        yield(exp)
      end
    end

    def eligible_repetition?(exp)
      return false unless exp.quantified?
      q = exp.quantifier
      return false unless q.max == -1
      return false if q.possessive?
      return false if exp.is_a?(Regexp::Expression::Group::Atomic)
      return false if sealed_by_ancestor?(exp)
      true
    end

    # A possessive quantifier on an ancestor only seals this expression if
    # the expression lies inside the quantified subtree (i.e. the ancestor is
    # not the expression itself).
    def sealed_by_ancestor?(exp)
      ancestor = exp.parent
      while ancestor
        return true if ancestor.is_a?(Regexp::Expression::Group::Atomic)
        if ancestor.quantified? && ancestor.quantifier.possessive? && ancestor != exp
          return true
        end
        ancestor = ancestor.parent
      end
      false
    end

    def analyze_repetition(exp)
      prefix_exps, suffix_exps = context_of(exp)

      ambiguity = ambiguous_unit(exp)
      return nil unless ambiguity

      unit, kind_and_reason = ambiguity
      terminator = terminator_for(suffix_exps, unit)
      return nil unless terminator

      prefix_text = concrete_prefix(prefix_exps, unit)
      witness = build_witness(exp, prefix_text, unit, terminator)
      return nil unless witness

      kind, reason_text = kind_and_reason
      full_reason = reason_text + suffix_reason(terminator)
      range = expression_range(exp)

      Finding.new(
        kind:            kind,
        range:           range,
        expression_text: exp.to_s,
        unit:            unit,
        witness:         witness,
        reason:          full_reason,
        verification:    @verify ? verify_witness(witness) : nil,
      )
    end

    # Returns [prefix_exps, suffix_exps] - the flattened expressions that
    # precede/follow the repetition inside its enclosing branch, plus the
    # continuation of that branch up to the root. Climbing stops at the first
    # enclosing alternation: siblings of another alternative are not
    # necessarily executed after the repetition.
    def context_of(exp)
      prefix = []
      suffix = []
      node = exp
      while node && !node.is_a?(Regexp::Expression::Root)
        parent = node.parent
        break unless parent

        # Collect siblings on the current level. When climbing through a
        # wrapper group (which is a single child of its parent), everything
        # after the group belongs to the suffix and everything before it to
        # the prefix.
        own_index = parent.expressions.index { |sib| sib.equal?(node) }
        if own_index
          parent.expressions.each_with_index do |sib, i|
            next if i == own_index
            (i < own_index ? prefix : suffix).concat(flatten(sib))
          end
        else
          # node is logically the wrapper itself; treat all siblings as
          # suffix context conservatively
          parent.expressions.each { |sib| suffix.concat(flatten(sib)) }
        end

        break if parent.is_a?(Regexp::Expression::Alternative) ||
                 parent.is_a?(Regexp::Expression::Conditional::Branch)
        node = parent
      end
      [prefix, suffix]
    end

    def flatten(exp)
      # Subtrees containing unsupported constructs (lookarounds,
      # backreferences, ...) cannot be turned into an equivalent fragment
      # regexp, so they are skipped by the conservative suffix/prefix probes.
      return [] if contains_limitation?(exp)
      return [exp] if exp.terminal?
      exp.flat_map.to_a.reject { |sub| sub.respond_to?(:decorative?) && sub.decorative? }
    end

    def contains_limitation?(exp)
      return false unless exp.respond_to?(:each_expression)
      exps = [exp]
      exps.concat(exp.each_expression.to_a.map(&:first)) unless exp.terminal?
      exps.any? do |node|
        ASSERTION_TOKENS.include?(node.token) || LIMITATIONS.key?([node.type, node.token])
      end
    end

    # -- ambiguity detection ------------------------------------------------

    # Returns [unit, reason] if one iteration of the body can consume a run
    # of +unit+ in more than one length, i.e. consecutive iterations overlap
    # on that unit. Returns nil when the body is single-valued on every
    # candidate unit.
    def ambiguous_unit(exp)
      body = body_expression(exp)
      each_pump_unit(body) do |unit|
        alt = overlapping_alternation(body, unit)
        if alt
          return [unit, alternation_reason(alt, unit)]
        end

        lengths = matchable_run_lengths(body, unit)
        if lengths.length >= 2
          nested = nested_flex_repetition(body, unit)
          if nested
            return [unit, nested_reason(nested, unit, lengths)]
          end
        end
        nullable = nullable_ambiguity(body, unit)
        return [unit, nullable] if nullable
      end
      nil
    end

    def alternation_reason(alternatives, unit)
      [
        :overlapping_alternatives,
        "alternatives #{alternation_labels(alternatives)} can both consume " \
        "the pump unit #{unit.inspect} from the same position, so a long " \
        "run can be split between branches in exponentially many ways",
      ]
    end

    def nested_reason(source, unit, lengths)
      [
        :nested_repetition,
        "the repetition at position #{source.ts} can absorb one or more " \
        "extra #{unit.inspect} units, so the boundary between outer " \
        "iterations is ambiguous (run lengths #{lengths.inspect})",
      ]
    end

    # A repetition body that can consume the unit but may also match empty
    # (typically because its only unit-consuming part is optional) makes the
    # consume/skip decision for every unit in a long run independent, which
    # multiplies the number of parses.
    def nullable_ambiguity(body, unit)
      return nil unless body_can_match_empty?(body)
      consuming = compile_prefix(body_source(body))
      return nil unless consuming && safe_match?(consuming, unit)

      source = nested_optional_source(body, unit)
      [
        :optional_iteration,
        "each iteration can either consume #{unit.inspect} or match empty" \
        "#{source ? " (via the optional repetition at position #{source.ts})" : ''}, " \
        "so the consume/skip choice for every unit is independent",
      ]
    end

    def body_can_match_empty?(body)
      re = compile_anchored(body_source(body))
      re && safe_match?(re, '')
    end

    def nested_optional_source(body, unit)
      find_expression(body) do |exp|
        next false if exp == body || !exp.quantified?
        next false unless exp.quantifier.min == 0
        next false if exp.quantifier.possessive?
        next false if sealed_node?(exp, body)
        core = exp.terminal? ? exp.to_s(:base) : exp.unquantified_clone.to_s
        re = compile_prefix(core)
        re && safe_match?(re, unit) ? exp : false
      end
    end

    # The quantified subtree. Groups carry the quantifier directly; for other
    # nodes (e.g. a quantified literal) the node itself is the body.
    def body_expression(exp)
      exp
    end

    # Yields candidate pump units: first single characters present in the
    # body, then short compound runs (e.g. 'ab'). Some overlapping
    # alternations only manifest on compound runs: in (a|b|ab), the
    # ambiguous family is the pump 'ab', not a single character.
    def each_pump_unit(body)
      return enum_for(__method__, body) unless block_given?

      singles = []
      collect_unit_chars(body, singles)
      seen = {}
      singles.uniq.each do |char|
        yield(char) unless seen[char]
        seen[char] = true
      end
      singles.uniq.permutation(2).each do |left, right|
        compound = left + right
        next if seen[compound]
        seen[compound] = true
        yield(compound)
      end
    end

    def collect_unit_chars(exp, chars)
      case exp
      when Regexp::Expression::Literal
        literal_text(exp).each_char { |c| chars << c }
      when Regexp::Expression::Alternation
        exp.alternatives.each { |alt| alt.each { |sub| collect_unit_chars(sub, chars) } }
      else
        if exp.terminal?
          sample = terminal_sample(exp)
          chars << sample if sample && sample.length == 1
        else
          exp.each_expression { |sub| collect_unit_chars(sub, chars) }
        end
      end
    end

    # A representative single character for terminal character classes/types.
    def terminal_sample(exp)
      return literal_text(exp)[0] if exp.is_a?(Regexp::Expression::Literal)
      return 'a' if exp.is_a?(Regexp::Expression::CharacterSet)
      return nil unless exp.is_a?(Regexp::Expression::CharacterType::Base)
      character_type_sample(exp.token)
    end

    def character_type_sample(token)
      { digit: '1', non_digit: 'a', word: 'a', non_word: '!',
        space: ' ', non_space: 'a', hex: 'a', non_hex: 'z',
        any: 'a', dot: 'a' }.fetch(token, nil)
    end

    # The bare characters of a literal, excluding free-spacing decorations
    # and the like.
    def literal_text(exp)
      text = exp.to_s(:base)
      free_spacing?(exp) ? text.gsub(/\s+/, '') : text
    end

    def free_spacing?(exp)
      exp.options && (exp.options[:x] || exp.options[:free_space])
    end

    # The distinct numbers of +unit+ occurrences that exactly one iteration
    # of the body can consume, checked empirically against short runs.
    def matchable_run_lengths(body, unit, max_run = 4)
      re = compile_anchored(body_source(body))
      return [] unless re
      (1..max_run).select do |n|
        safe_match?(re, unit * n)
      end
    end

    def body_source(body)
      return body.to_s(:base) if body.terminal?
      body.unquantified_clone.to_s
    end

    # Structural source 1: an alternation with at least two alternatives that
    # can begin by consuming the pump unit. The alternatives need not start
    # with the very same string - a strict prefix relation (e.g. b vs ab on
    # the run 'abab...') also creates an ambiguous split. Sealed alternation
    # regions are skipped.
    def overlapping_alternation(body, unit)
      find_expression(body) do |exp|
        next false unless exp.is_a?(Regexp::Expression::Alternation)
        next false if sealed_node?(exp, body)
        alternatives = exp.alternatives
        pair = ambiguous_alternative_pair(alternatives, unit)
        next false unless pair
        pair
      end
    end

    # Finds two alternatives that participate in distinct tilings of the
    # same unit run reaching a shared position (a small prefix DP). A run
    # that can be consumed as one alternative OR as a sequence of others is
    # the pump lemma shape for exponential ambiguity. Alternating-cadence
    # overlaps (ab vs aba on 'abab') do not admit such a shared tiling and
    # are excluded.
    def ambiguous_alternative_pair(alternatives, unit)
      run = unit * 5
      ways = Array.new(run.length + 1) { [] }
      ways[0] = [[]]
      (0...run.length).each do |pos|
        next if ways[pos].empty?
        alternatives.each_with_index do |alt, index|
          text = prefix_match_text(alt, run[pos..])
          next if text.nil? || text.empty?
          next unless run[pos, text.length] == text
          new_pos = pos + text.length
          next if new_pos > run.length
          # cap histories so this probe stays tiny even when the run is
          # genuinely ambiguous; two distinct histories are already enough
          ways[pos].each do |history|
            candidate = history + [index]
            ways[new_pos] << candidate unless ways[new_pos].length >= 32 ||
                                            ways[new_pos].include?(candidate)
          end
        end
      end
      (1..run.length).each do |pos|
        histories = ways[pos].uniq
        next unless histories.length >= 2
        used = histories.flat_map(&:itself).uniq.map { |i| alternatives[i] }.uniq
        return used.first(2) if used.length >= 2
      end
      nil
    end

    def prefix_match_text(alternative, run)
      re = compile_prefix(alternative.to_s)
      return nil unless re
      data = safe_match_data(re, run)
      return nil unless data
      data[0]
    end

    def alternation_labels(alternatives)
      texts = alternatives.map { |alt| alt.to_s.inspect }
      texts.length == 2 ? texts.join(' and ') : texts.join(', ')
    end

    def first_backtrackable_child(sequence)
      sequence.expressions.find do |exp|
        next false if exp.is_a?(Regexp::Expression::Anchor::Base)
        next false if sealed_node?(exp, sequence)
        true
      end
    end

    # Structural source 2: a nested repetition that can absorb a pump unit
    # in a way that overlaps with outer iterations. This includes unbounded
    # inner repetitions (a+) and - crucially - optional inner repetitions
    # that can also match the unit (a?), since the choice of whether each
    # optional iteration consumes a unit multiplies across the whole run.
    # Bounded non-optional inner repetitions (a{1,2}) only yield polynomially
    # many splits and are excluded.
    def nested_flex_repetition(body, unit)
      find_expression(body) do |exp|
        next false if exp == body || !exp.quantified?
        next false if exp.quantifier.possessive?
        next false if sealed_node?(exp, body)
        next false unless exp.quantifier.max == -1
        nested_repetition_absorbs?(exp, unit) ? exp : false
      end
    end

    def nested_repetition_absorbs?(exp, unit)
      own = compile_anchored(fragment_source(exp, with_quantifier: false))
      return false unless own && safe_match?(own, unit)
      true
    end

    # Generic depth-first search honoring sealed regions.
    def find_expression(exp, &block)
      return nil if sealed_node?(exp, nil) && !exp.is_a?(Regexp::Expression::Root)
      result = block.call(exp)
      return result unless result == false || result.nil?
      return nil if exp.terminal?
      exp.expressions.each do |child|
        found = find_expression(child, &block)
        return found if found
      end
      nil
    end

    def sealed_node?(exp, _root)
      return true if exp.is_a?(Regexp::Expression::Group::Atomic)
      return true if exp.quantified? && exp.quantifier.possessive?
      false
    end

    def fragment_source(exp, with_quantifier: true)
      source = exp.terminal? ? exp.to_s(:base) : exp.unquantified_clone.to_s
      source += exp.quantifier.to_s if with_quantifier && exp.quantified?
      source
    end

    # -- suffix (inevitable failure) detection ------------------------------

    # Returns a concrete terminator string if the suffix cannot absorb an
    # arbitrarily long run of the pump unit. The search is deliberately
    # conservative: any suffix construct that could plausibly absorb the run
    # prevents a proof and yields nil.
    def terminator_for(suffix_exps, unit)
      terminator = nil
      suffix_exps.each do |exp|
        if terminator
          break
        elsif exp.is_a?(Regexp::Expression::Anchor::Base)
          if terminator_anchor?(exp)
            terminator = terminator_anchor_text(exp, unit)
          end
          # other anchors (e.g. word boundary) consume nothing and are skipped
        elsif cannot_start_with_unit?(exp, unit)
          terminator = terminal_char_for(exp, unit)
        elsif absorbable?(exp, unit)
          # an unbounded suffix expression that can swallow the pump unit
          # absorbs the run, so failure is not inevitable
          return nil
        else
          # unknown suffix construct; stay conservative
          return nil
        end
      end
      terminator
    end

    def terminator_anchor?(exp)
      exp.is_a?(Regexp::Expression::Anchor::Base) &&
        TERMINATOR_ANCHORS.include?(exp.token)
    end

    def terminator_anchor_text(anchor, unit)
      if anchor.token == :bol && unit != '\n'
        '\n' unless unit == '\n'
      else
        choose_non_unit(unit)
      end
    end

    def choose_non_unit(unit)
      candidates = %w[b ! #]
      candidates.find { |c| c != unit } || '\x00'
    end

    # True if the expression definitely cannot match a string starting with
    # the pump unit.
    def cannot_start_with_unit?(exp, unit)
      return true if exp.is_a?(Regexp::Expression::Literal) &&
                     !literal_text(exp).empty? && !literal_text(exp).start_with?(unit)
      re = compile_anchored(leading_fragment_source(exp))
      return false unless re
      !safe_match?(re, unit)
    end

    def leading_fragment_source(exp)
      if exp.terminal?
        exp.to_s(:base)
      else
        first = first_backtrackable_child(exp)
        first ? fragment_source(first, with_quantifier: false) : nil
      end
    end

    def terminal_char_for(exp, unit)
      if exp.is_a?(Regexp::Expression::Literal)
        literal_text(exp)[0]
      else
        source = leading_fragment_source(exp)
        re = compile_anchored(source)
        char = %w[b c ! # z].reject { |candidate| candidate == unit }.find do |candidate|
          re && safe_match?(re, candidate)
        end
        char
      end
    end

    # True if this suffix expression can swallow an arbitrarily long run of
    # the pump unit itself.
    def absorbable?(exp, unit)
      return false unless exp.quantified? && exp.quantifier.max == -1
      return false if exp.quantifier.possessive?
      core = exp.terminal? ? exp.to_s(:base) : exp.unquantified_clone.to_s
      re = compile_anchored(core)
      re && safe_match?(re, unit) && !safe_match?(re, '')
    end

    def suffix_reason(terminator)
      "; the following suffix cannot absorb the run and fails once a " \
      "#{terminator.inspect} is encountered, so every split is retried"
    end

    # The AST range reported for a finding covers the quantified expression
    # including its quantifier.
    def expression_range(exp)
      start = exp.ts
      finish = exp.te + (exp.full_length - exp.base_length)
      start...finish
    end

    # Derives a concrete fixed prefix by greedily matching the flattened
    # prefix against a short pump run followed by the terminator. Prefixes
    # that themselves absorb the unit simply contribute a shorter (possibly
    # empty) concrete prefix, which is still a valid witness.
    def concrete_prefix(prefix_exps, unit)
      return '' if prefix_exps.empty?
      source = prefix_exps.map { |exp| exp.to_s }.join
      seed = prefix_seed_text(prefix_exps, unit)
      probe = seed + unit * 8
      re = compile_prefix(source)
      return '' unless re
      data = safe_match_data(re, probe)
      return '' unless data
      matched = data[0]
      fixed_prefix(matched, probe, seed, unit)
    rescue StandardError
      ''
    end

    # Builds a short concrete string that the prefix can match, independent of
    # the pump unit (e.g. 'pre' for /pre(a|aa)*b). Falls back to the unit.
    def prefix_seed_text(prefix_exps, unit)
      seed = ''.dup
      prefix_exps.each do |exp|
        next if exp.is_a?(Regexp::Expression::Anchor::Base)
        if exp.is_a?(Regexp::Expression::Literal) && !exp.text.empty?
          seed << literal_text(exp)
        else
          char = representative_char(exp)
          seed << char if char
        end
        break if seed.length >= 4
      end
      seed.empty? ? unit : seed
    end

    def representative_char(exp)
      sample = terminal_sample(exp)
      return sample if sample
      sub = exp.respond_to?(:each_expression) &&
            exp.each_expression.to_a.map(&:first).find { |e| terminal_sample(e) }
      sub && terminal_sample(sub)
    end

    # Keeps the matched prefix up to the last character that belongs to the
    # fixed seed context, stripping pump characters that a trailing prefix
    # repetition swallowed.
    def fixed_prefix(matched, probe, seed, unit)
      tail_start = seed.length
      return matched if matched.length < tail_start
      fixed = matched[0...tail_start]
      trailing = matched[tail_start..].to_s
      return fixed if trailing.empty? || repetition_of_unit?(trailing, unit)
      matched
    end

    def repetition_of_unit?(string, unit)
      return false if unit.empty? || (string.length % unit.length).nonzero?
      string == unit * (string.length / unit.length)
    end

    def build_witness(exp, prefix_text, unit, terminator)
      Witness.new(
        prefix:  prefix_text,
        pump:    unit,
        suffix:  terminator,
        growth:  "each extra #{unit.inspect} multiplies the ways of " \
                 "splitting the run across repetitions of #{exp.to_s.inspect}",
        lengths: @pump_lengths,
      )
    end

    # -- compilation and bounded probing -------------------------------------

    def compile_anchored(source, anchoring: true)
      return nil if source.nil? || source.empty?
      wrapped = anchoring ? '\\A(?:' + source + ')\\z' : '\\A(?:' + source + ')'
      quiet_regexp(wrapped)
    rescue StandardError
      nil
    end

    # Anchored only at the start: used to check whether an expression can
    # begin by consuming a given pump unit without matching it completely.
    def compile_prefix(source)
      return nil if source.nil? || source.empty?
      quiet_regexp('\A(?:' + source + ')')
    rescue StandardError
      nil
    end

    # Compiles a probe fragment without emitting warnings to $stderr.
    def quiet_regexp(fragment)
      previous = $VERBOSE
      $VERBOSE = nil
      Regexp.new(fragment)
    ensure
      $VERBOSE = previous
    end

    def safe_match?(re, string)
      result = safe_match_data(re, string)
      !result.nil?
    end

    def safe_match_data(re, string)
      re.match(string)
    rescue Regexp::TimeoutError, RegexpError
      nil
    end

    # Auxiliary verification only. It runs very small inputs under a strict
    # per-match timeout; it never infers risk from a single long hang.
    def verify_witness(witness)
      lengths = witness.lengths
      observations = []
      source = matcher_source
      re = begin
             Regexp.new(source, timeout: @timeout)
           rescue ArgumentError
             Regexp.new(source) # Ruby without per-match timeouts
           rescue StandardError
             return Verification.new(method: :skipped, timeout: @timeout,
                                   observations: [],
                                   summary: 'matcher could not be compiled')
           end

      timeout_supported = re.respond_to?(:timeout) ? !re.timeout.nil? : false

      lengths.each do |n|
        string = witness.prefix + witness.pump * n + witness.suffix
        duration = timed_match(re, string)
        observations << { length: string.length, repetitions: n,
                          timed_out: duration >= @timeout * 0.95,
                          seconds: duration.round(4) }
      end
      timeouts = observations.count { |o| o[:timed_out] }
      summary =
        if !timeout_supported
          'auxiliary timeout unsupported on this Ruby; the static proof is ' \
          'the basis of the report'
        elsif timeouts.positive?
          "#{timeouts} of #{observations.length} small inputs exceeded the " \
          "#{@timeout}s budget under a strict per-match timeout"
        else
          'all small inputs matched quickly; the running engine appears to ' \
          'linearize this pattern, so the static proof is the basis of the report'
        end
      Verification.new(method: :bounded_timeout, timeout: @timeout,
                       observations: observations, summary: summary)
    end

    def matcher_source
      @matcher_source ||= begin
        source = @source.is_a?(::Regexp) ? @source.source : @source.to_s
        source
      end
    end

    def timed_match(re, string)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        re.match?(string)
      rescue Regexp::TimeoutError
        # expected for engines that do not linearize
      end
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    end
  end
end
