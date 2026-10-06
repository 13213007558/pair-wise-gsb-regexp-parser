# frozen_string_literal: true

class Regexp::Parser
  class CompositionError < ParserError; end

  # Structurally combines parsed regular expressions without concatenating
  # their source strings. Captures in every operand are cloned and renumbered,
  # and references inside those clones are redirected to the new copies.
  module Composition
    OPTIONS = %i[i m x].freeze
    POLICIES = %i[raise rename keep].freeze
    @root_wrapper_serial = 0

    class << self
      attr_accessor :root_wrapper_serial
    end

    class Result < Regexp::Expression::Root
      attr_accessor :composition_occurrences

      def self.construct_defaults
        { type: :expression, token: :root, ts: 0, level: 0,
          set_level: 0, conditional_level: 0, text: '' }
      end

      def initialize_copy(orig)
        super
        old_to_new = {}
        stack = [[orig, self]]

        until stack.empty?
          old, copy = stack.pop
          old_to_new[old] = copy
          next if old.terminal?

          old.expressions.each_with_index do |child, index|
            stack << [child, copy.expressions[index]]
          end
        end

        self.composition_occurrences = orig.composition_occurrences.map do |occurrence|
          occurrence = occurrence.dup
          occurrence[:path] = occurrence[:path].dup
          occurrence[:group] = old_to_new[occurrence[:group]]
          occurrence
        end
      end

      def capture_map
        mapping = Hash.new { |hash, key| hash[key] = [] }

        composition_occurrences.each do |occurrence|
          mapping[occurrence[:source]] << {
            number: occurrence[:group].number,
            name: occurrence[:group].respond_to?(:name) ? occurrence[:group].name : nil,
            path: occurrence[:path].dup,
          }
        end

        mapping
      end

      def extract(match_data)
        mapping = Hash.new { |hash, key| hash[key] = [] }

        capture_map.each do |source, targets|
          targets.each do |target|
            value = match_data[target[:number]]
            mapping[source] << value

            name = (source.respond_to?(:name) ? source.name : nil) || target[:name]
            mapping[name] << value if name
          end
        end

        mapping
      end
    end

    class << self
      def concat(*fragments, on_name_conflict: :raise)
        prepared = fragments.flatten.map.with_index do |fragment, index|
          prepare(fragment, [:sequence, index])
        end

        build_root(prepared, on_name_conflict) do |root, copies|
          copies.each do |copy|
            if copy.is_a?(Regexp::Expression::Root)
              move_expressions(copy, root)
            else
              root << copy
            end
          end
        end
      end

      def alternate(*fragments, on_name_conflict: :raise)
        prepared = fragments.flatten.map.with_index do |fragment, index|
          prepare(fragment, [:branch, index])
        end

        build_root(prepared, on_name_conflict) do |root, copies|
          alternation = Regexp::Expression::Alternation.construct(
            type: :meta, token: :alternation, text: '|'
          )

          copies.each do |copy|
            branch = Regexp::Expression::Alternative.construct
            if copy.is_a?(Regexp::Expression::Root)
              move_expressions(copy, branch)
            else
              branch << copy
            end
            alternation.expressions << branch
          end

          root << alternation
        end
      end

      def repeat(fragment, quantifier, on_name_conflict: :raise)
        prepared = [prepare(fragment, [:repetition, 0])]

        build_root(prepared, on_name_conflict) do |root, copies|
          if copies.first.is_a?(Regexp::Expression::Group::Base) &&
             !copies.first.is_a?(Regexp::Expression::Root)
            copies.first.quantifier = build_quantifier(quantifier)
            root << copies.first
          else
            passive = Regexp::Expression::Group::Passive.construct(
              type: :group, token: :passive, text: '(?:'
            )
            move_expressions(copies.first, passive)
            passive.quantifier = build_quantifier(quantifier)
            root << passive
          end
        end
      end

      def capture(fragment, name, on_name_conflict: :raise)
        prepared = [prepare(fragment, [:capture, 0])]
        prepared.first[:extra_capture_name] = name

        build_root(prepared, on_name_conflict) do |root, copies|
          group = Regexp::Expression::Group::Named.construct(
            type: :group, token: :named, text: "(?<#{name}>"
          )
          group.composition_synthetic = true
          if copies.first.is_a?(Regexp::Expression::Root)
            move_expressions(copies.first, group)
          else
            group << copies.first
          end
          root << group
        end
      end

      private

      def prepare(fragment, path)
        if fragment.is_a?(Result)
          root = fragment.clone
          root.composition_occurrences.each do |occurrence|
            occurrence[:path] = path + occurrence[:path]
          end
          occurrences = root.composition_occurrences
        else
          source = fragment.is_a?(Regexp::Expression::Root) ? fragment.clone : Regexp::Parser.parse(fragment)
          source.assign_referenced_expressions
          root = source.clone
          occurrences = []

          pair_traversal(source, root) do |old, copy|
            next unless old.is_a?(Regexp::Expression::Group::Capture)

            copy.composition_source = old
            copy.composition_path = path
            occurrences << { source: old, group: copy, path: path.dup }
          end
          bind_composition_targets(source, root)
        end

        root_call_name = root_call_name(root, path)
        has_root_call = !root_call_name.nil?
        has_option_switch = contains_option_switch?(root)
        wrapper = wrap_fragment(
          root, has_root_call, has_option_switch, root_call_name
        )

        { wrapper: wrapper, occurrences: occurrences, path: path }
      end

      def wrap_fragment(root, has_root_call, has_option_switch, root_call_name)
        wrapper = root

        if has_root_call
          capture = root_call_group(root_call_name)
          capture.composition_synthetic = true
          move_expressions(wrapper, capture)
          wrapper = capture
        end

        unless root.options.empty?
          option_group = Regexp::Expression::Group::Options.construct(
            type: :group, token: :options, text: options_group_text(root.options)
          )
          option_group.option_changes = options_changes(root.options)
          move_expressions(wrapper, option_group)
          wrapper = option_group
        end

        if has_option_switch
          passive = Regexp::Expression::Group::Passive.construct(
            type: :group, token: :passive, text: '(?:'
          )
          move_expressions(wrapper, passive)
          wrapper = passive
        end

        if has_root_call
          wrapper.traverse do |_, copy, _|
            copy.composition_target = capture if root_call?(copy)
          end
        end

        wrapper
      end

      def build_root(prepared, policy)
        root = Result.construct
        copies = prepared.map { |item| item[:wrapper] }
        yield root, copies

        resolve_name_conflicts(root, prepared, policy)
        number_captures(root)
        rewrite_references(root)
        assign_referenced_expressions(root)
        root.recursively_update_nesting_levels
        root.composition_occurrences = prepared.flat_map { |item| item[:occurrences] }
        validate_regexp(root)
        root
      end

      def resolve_name_conflicts(root, prepared, policy)
        validate_policy(policy)
        return if policy == :keep

        groups = named_non_synthetic_groups(root)
        protected_names = prepared.map { |item| item[:extra_capture_name] }.compact

        groups.map(&:name).uniq.sort.each do |name|
          matching = groups.select { |group| group.name == name }
          conflicting = protected_names.include?(name) || matching.map(&:composition_path).uniq.length > 1
          next unless conflicting

          if policy == :raise
            raise CompositionError,
                  "cannot combine capture name #{name.inspect}; " \
                  "provide on_name_conflict: :rename or :keep"
          end

          rename_matching_groups(root, matching, name, protected_names)
         end
      end

      def validate_policy(policy)
        return if POLICIES.include?(policy)

        raise ArgumentError,
              "on_name_conflict must be one of #{POLICIES.map(&:inspect).join(', ')}"
      end

      def rename_matching_groups(root, groups, old_name, protected_names)
        groups.group_by(&:composition_path).each do |_, operand_groups|
          candidate = unique_name(root, old_name, protected_names)
          operand_groups.each { |group| group.name = candidate }
        end
      end

      def unique_name(root, base_name, protected_names)
        suffix = 1
        suffix += 1 while name_taken?(root, "#{base_name}_#{suffix}", protected_names)
        "#{base_name}_#{suffix}"
      end

      def name_taken?(root, name, protected_names)
        protected_names.include?(name) ||
          named_non_synthetic_groups(root).any? { |group| group.name == name }
      end

      def number_captures(root)
        total = 0
        counts = Hash.new(0)
        stack = [[root, root]]

        until stack.empty?
          parent, exp = stack.pop
          if exp.is_a?(Regexp::Expression::Group::Capture)
            total += 1
            counts[parent] += 1
            exp.number = total
            exp.number_at_level = counts[parent]
          end

          next if exp.terminal?
          exp.expressions.reverse_each { |child| stack << [exp, child] }
        end
      end

      def rewrite_references(root)
        root.traverse do |_, exp, _|
          if exp.is_a?(Regexp::Expression::Backreference::Base)
            rewrite_backreference(exp)
          elsif exp.is_a?(Regexp::Expression::Conditional::Condition)
            rewrite_condition(exp)
          end
        end
      end

      def assign_referenced_expressions(root)
        targets = {}
        targets[0] = [root] if root.instance_of?(Regexp::Expression::Root)
        referrers = []

        root.traverse do |_, exp, _|
          if exp.referential?
            referrers << exp
          elsif exp.is_a?(Regexp::Expression::Group::Capture)
            (targets[exp.identifier] ||= []) << exp
          end
        end

        referrers.each do |exp|
          target = exp.composition_target
          target = target_reference(exp, targets) if target.nil?
          exp.referenced_expressions = target.is_a?(Array) ? target : [target]

          if exp.is_a?(Regexp::Expression::Conditional::Expression)
            exp.condition.referenced_expressions = exp.referenced_expressions
          end
        end
      end

      def target_reference(exp, targets)
        target = targets[exp.reference]
        return target unless target.nil?

        raise CompositionError,
              "invalid reference chain #{exp.text.inspect} -> #{exp.reference.inspect}; " \
              "the referenced capture is not present in the same composed fragment"
      end

      def rewrite_backreference(exp)
        target = target_expression(exp)
        target_groups = target.is_a?(Array) ? target : [target]
        numeric_target = target_groups.first

        if target_groups.length == 1 &&
           target_groups.first.is_a?(Regexp::Expression::Group::Named) &&
           exp.is_a?(Regexp::Expression::Backreference::NumberCall)
          exp.text = named_backreference_text(exp, target_groups.first.name)
        elsif exp.is_a?(Regexp::Expression::Backreference::Number)
          number = target_number(exp, numeric_target)
          exp.number = number
          exp.effective_number = number if exp.respond_to?(:effective_number=)
          exp.text = number_backreference_text(exp, number)
        elsif named_target?(target_groups)
          exp.name = target_groups.first.name
          exp.text = named_backreference_text(exp, target_groups.first.name)
        end
      end

      def rewrite_condition(exp)
        target = exp.composition_target || target_expression(exp)
        target_groups = target.is_a?(Array) ? target : [target]
        numeric_target = target_groups.first

        if named_target?(target_groups)
          exp.text = named_condition_text(exp, target_groups.first.name)
        else
          exp.text = "(#{target_number(exp, numeric_target)})"
        end
      end

      def named_target?(target_groups)
        target_groups.any? &&
          target_groups.all? { |group| group.is_a?(Regexp::Expression::Group::Named) } &&
          target_groups.map(&:name).uniq.length == 1
      end

      def named_condition_text(exp, name)
        quoted = exp.text.include?("'")
        opening = quoted ? "('" : '(<'
        closing = quoted ? "')" : '>)'
        "#{opening}#{name}#{closing}"
      end

      def target_expression(exp)
        target = exp.composition_target
        return target if target.is_a?(Array)
        return target unless target.nil?

        referenced = exp.referenced_expression
        if referenced.is_a?(Regexp::Expression::Conditional::Expression)
          referenced.condition
        else
          referenced
        end
      end

      def target_number(exp, target)
        if target == :root
          wrapper = exp
          wrapper = wrapper.parent until wrapper.nil? ||
            (wrapper.respond_to?(:composition_synthetic) && wrapper.composition_synthetic)
          if wrapper.respond_to?(:composition_synthetic) &&
             wrapper.composition_synthetic &&
             wrapper.is_a?(Regexp::Expression::Group::Capture)
            return wrapper.number
          end

          raise CompositionError, "unresolved root reference in reference chain"
        end

        target.number
      end

      def number_backreference_text(exp, number)
        if exp.is_a?(Regexp::Expression::Backreference::NumberRecursionLevel)
          "\\k<#{number}#{signed_level(exp.recursion_level)}>"
        elsif exp.text.start_with?('\\g')
          "\\g<#{number}>"
        elsif exp.text.start_with?('\\k')
          "\\k<#{number}>"
        else
          "\\#{number}"
        end
      end

      def named_backreference_text(exp, name)
        quoted = exp.text.include?("'")
        opening = quoted ? "'" : '<'
        closing = quoted ? "'" : '>'
        prefix = exp.text[1]

        if exp.is_a?(Regexp::Expression::Backreference::NameRecursionLevel)
          "\\#{prefix}#{opening}#{name}#{exp.recursion_level_sign}#{exp.recursion_level}#{closing}"
        else
          "\\#{prefix}#{opening}#{name}#{closing}"
        end
      end

      def signed_level(level)
        level >= 0 ? "+#{level}" : level.to_s
      end

      def validate_regexp(root)
        ::Regexp.new(root.to_s)
      rescue RegexpError => error
        raise CompositionError,
              "combined expression is not valid: #{root.to_s.inspect} (#{error.message})"
      end

      def contains_root_call?(root)
        root.traverse do |_, exp, _|
          return true if root_call?(exp)
        end
        false
      end

      def root_call_name(root, path)
        return nil unless contains_root_call?(root)

        base = "__composition_root_#{fragment_id(path)}"
        candidate = "#{base}_#{self.root_wrapper_serial += 1}"
        candidate = "#{candidate}_#{self.root_wrapper_serial += 1}" while root_name_taken?(root, candidate)
        candidate
      end

      def root_name_taken?(root, name)
        root.traverse do |_, exp, _|
          return true if exp.is_a?(Regexp::Expression::Group::Named) && exp.name == name
        end
        false
      end

      def fragment_id(path)
        path.map { |part| part.to_s.gsub(/[^a-zA-Z0-9_]/, '_') }.join('_')
      end

      def root_call_group(name)
        Regexp::Expression::Group::Named.construct(
          type: :group, token: :named, text: "(?<#{name}>"
        )
      end

      def root_call?(exp)
        return false unless exp.is_a?(Regexp::Expression::Backreference::NumberCall)
        return true if exp.composition_target == :root

        exp.text =~ /\A\\g[<']0+[>']\z/ && exp.number == 0
      end

      def contains_option_switch?(root)
        root.traverse do |_, exp, _|
          return true if exp.is_a?(Regexp::Expression::Group::Options) &&
                          exp.token == :options_switch
        end
        false
      end

      def move_expressions(source, target)
        source.expressions.each { |child| target << child }
        source.expressions.clear
        self_target = target.expressions.include?(target)
        target.expressions.delete(target) if self_target
      end

      def pair_traversal(left, right)
        stack = [[left, right]]

        until stack.empty?
          old, copy = stack.pop
          yield old, copy

          next if old.terminal?
          old.expressions.each_with_index do |child, index|
            stack << [child, copy.expressions[index]]
          end
        end
      end

      def bind_composition_targets(source, copy)
        old_to_copy = {}
        pair_traversal(source, copy) { |old, cloned| old_to_copy[old] = cloned }

        pair_traversal(source, copy) do |old, cloned|
          next unless old.referential?

          target =
            if old.is_a?(Regexp::Expression::Conditional::Condition)
              conditional_for_condition(source, old).referenced_expression
            elsif old.referenced_expressions
              old.referenced_expressions
            else
              old.referenced_expression
            end
          if target.equal?(source)
            cloned.composition_target = :root
          elsif target
            mapped_target =
              if target.is_a?(Array)
                target.map { |target_exp| old_to_copy[target_exp] }
              else
                old_to_copy[target]
              end
            cloned.composition_target = mapped_target
            if cloned.is_a?(Regexp::Expression::Conditional::Condition)
              cloned.parent.composition_target = mapped_target
            end
          end
        end
      end

      def conditional_for_condition(root, condition)
        conditional = nil
        root.traverse do |_, exp, _|
          if exp.is_a?(Regexp::Expression::Conditional::Expression) && exp.condition.equal?(condition)
            conditional = exp
          end
        end
        conditional
      end

      def named_non_synthetic_groups(root)
        groups = []
        root.traverse do |_, exp, _|
          if exp.is_a?(Regexp::Expression::Group::Named) && !exp.composition_synthetic
            groups << exp
          end
        end
        groups
      end

      def build_quantifier(description)
        case description
        when String
          text = description
        when Integer
          text = "{#{description},#{description}}"
        when Range
          text = "{#{description.min},#{description.max}}"
        else
          raise ArgumentError, 'quantifier must be a String, Integer, or Range'
        end

        Regexp::Expression::Quantifier.construct(
          text: text, token: quantifier_token(text)
        )
      end

      def quantifier_token(text)
        base = text[0]
        token_prefix =
          case base
          when '?' then :zero_or_one
          when '*' then :zero_or_more
          when '+' then :one_or_more
          else :interval
          end

        mode = text[/.([?+])/, 1]
        suffix = mode == '?' ? :reluctant : mode == '+' ? :possessive : nil
        suffix ? "#{token_prefix}_#{suffix}".to_sym : token_prefix
      end

      def options_group_text(options)
        enabled = OPTIONS.select { |flag| options[flag] == true }.map(&:to_s).join
        disabled = OPTIONS.reject { |flag| options[flag] == true }.map(&:to_s).join
        "(?#{enabled}-#{disabled}:"
      end

      def options_changes(options)
        OPTIONS.each_with_object({}) do |flag, changes|
          changes[flag] = options[flag] == true
        end
      end
    end
  end
end
