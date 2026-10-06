# frozen_string_literal: true

class Regexp::Parser
  class CompositionError < Regexp::Parser::Error
    attr_reader :reference_chain

    def initialize(message, reference_chain = nil)
      @reference_chain = reference_chain || []
      super(chain_message(message))
    end

    private

    def chain_message(message)
      return message if reference_chain.empty?

      "#{message} (reference chain: #{reference_chain.map(&:to_s).join(' -> ')})"
    end
  end

  class MappedCapture < Struct.new(:fragment, :old_number, :old_name,
                                  :number, :name, :path)
    def value(match)
      match[name || number]
    end
  end

  class CaptureMap
    include Enumerable

    def initialize(entries = [])
      @entries = entries
    end

    def each(&block)
      @entries.each(&block)
    end

    def [](fragment, name_or_number = nil)
      entries = select { |entry| entry.fragment == fragment }
      return entries if name_or_number.nil?

      entries.select do |entry|
        entry.old_name == name_or_number || entry.old_number == name_or_number
      end
    end

    def by_path(path)
      find { |entry| entry.path == Array(path) }
    end

    def to_a
      @entries
    end

    def restore(match)
      each_with_object({}) do |entry, restored|
      key = entry.old_name || entry.old_number
      restored[[entry.fragment, key, entry.path]] = entry.value(match)
      end
    end
  end

  class Fragment
    attr_reader :expression, :id

    def self.[](expression, id: nil)
      new(expression, id: id)
    end

    def initialize(expression, id: nil)
      @expression = expression
      @id = id || "fragment_#{object_id}"
    end

    def concat(other, on_name_conflict: :raise)
      Regexp::Parser.concat(self, self.class.new(other),
                           on_name_conflict: on_name_conflict)
    end
    alias_method :+, :concat

    def alternate(*others, on_name_conflict: :raise)
      fragments = others.map { |other| self.class.new(other) }
      Regexp::Parser.alternate(self, *fragments,
                               on_name_conflict: on_name_conflict)
    end
    alias_method :|, :alternate

    def repeat(quantifier, mode: nil, on_name_conflict: :raise)
      Regexp::Parser.repeat(self, quantifier, mode: mode,
                                     on_name_conflict: on_name_conflict)
    end
  end

  Regexp::Expression::Base.class_eval { attr_reader :composition_capture_map }

  class << self
    def fragment(expression, id: nil)
      Fragment.new(expression, id: id)
    end
    alias_method :[], :fragment

    def concat(*fragments, on_name_conflict: :raise)
      fragments = fragments_from(fragments)
      root = Regexp::Expression::Root.construct
      prepared = fragments.each_with_index.map do |fragment, index|
        prepare_fragment(fragment, [index])
      end
      prepared.each { |item| item[:nodes].each { |node| root << node } }
      finalize(root, prepared, on_name_conflict)
    end

    def alternate(*fragments, on_name_conflict: :raise)
      fragments = fragments_from(fragments)
      root = Regexp::Expression::Root.construct
      alternation = Regexp::Expression::Alternation.construct(text: '|', token: :alternation)

      prepared = fragments.each_with_index.map do |fragment, index|
        alternative = Regexp::Expression::Alternative.construct
        item = prepare_fragment(fragment, [index])
        item[:nodes].each { |node| alternative << node }
        alternation.expressions << alternative
        item
      end

      root.expressions << alternation
      finalize(root, prepared, on_name_conflict)
    end

    def repeat(fragment, quantifier, mode: :greedy, on_name_conflict: :raise)
      fragment = fragments_from([fragment]).first
      root = Regexp::Expression::Root.construct
      item = prepare_fragment(fragment, [:repeat])
      wrapper = passive_group
      item[:nodes].each { |node| wrapper << node }
      wrapper.quantifier = quantifier_expression(quantifier, mode)
      root.expressions << wrapper
      finalize(root, [item], on_name_conflict)
    end

    private

    def fragments_from(fragments)
      fragments.flatten.map do |fragment|
        fragment.is_a?(Fragment) ? fragment : Fragment.new(fragment)
      end
    end

    def prepare_fragment(fragment, prefix)
      source = fragment.expression
      cloned = source.dup
      root_call = root_call?(cloned)

      if root_call && !source.is_a?(Regexp::Expression::Root)
        raise CompositionError.new('cannot compose a non-root fragment containing \\g<0>',
                                  [root_call.text])
      end

      nodes = source.is_a?(Regexp::Expression::Root) ? wrap_root(cloned) : [cloned]

      if root_call
        capture = Regexp::Expression::Group::Capture.construct(text: '(', token: :capture)
        capture.instance_variable_set(:@composition_synthetic_root, true)
        nodes.each { |node| capture << node }
        nodes = [capture]
      end

      anchor_map = assign_identities(fragment, nodes, prefix, root_call)
      assign_references(nodes, root_call, anchor_map)
      { fragment: fragment, nodes: nodes }
    end

    def wrap_root_options(root)
      options = root.options || {}
      return root.expressions.to_a if options.empty?

      text = '(?:'
      group = Regexp::Expression::Group::Options.construct(text: text, token: :options,
                                                   options: options)
      group.option_changes = {}
      root.expressions.each { |node| group << node }
      [group]
    end

    def wrap_root(root)
      nodes = wrap_root_options(root)
      options = root.options || {}
      if options.empty?
        wrapper = passive_group
        nodes.each { |node| wrapper << node }
        return [wrapper]
      end

      enabled = %i[i m x].select { |flag| options[flag] }
      disabled = %i[i m x] - enabled
      reset = Regexp::Expression::Group::Options.construct(
        text: "(?#{enabled.join}-#{disabled.join}:", token: :options,
        options: {})
      reset.option_changes = {}
      enabled.each { |flag| reset.option_changes[flag] = true }
      disabled.each { |flag| reset.option_changes[flag] = false }
      nodes.each { |node| reset << node }
      [reset]
    end

    def assign_identities(fragment, nodes, prefix, root_call)
      old_number = 0
      prepared_groups = captures(nodes).reject do |node|
        node.instance_variable_get(:@composition_synthetic_root)
      end
      source_groups = prepared_groups
      anchor_map = {}
      old_anchors = prepared_groups.map { |node| node.instance_variable_get(:@composition_anchor) }

      prepared_groups.each do |node|
        next if node.instance_variable_get(:@composition_synthetic_root)
        if node.instance_variable_get(:@composition_identity).nil?
          old_number += 1
          node.instance_variable_set(:@composition_identity, fragment.id)
          node.instance_variable_set(:@composition_old_number, old_number)
          if node.instance_of?(Regexp::Expression::Group::Named)
            node.instance_variable_set(:@composition_old_name, node.name.dup)
          end
        end
      end

      captures(nodes).each do |node|
        if node.instance_variable_get(:@composition_synthetic_root)
          node.instance_variable_set(:@composition_anchor, :root)
          node.instance_variable_set(:@composition_path, prefix)
          next
        end

        anchor = [object_id, @composition_anchor_serial = (@composition_anchor_serial || 0) + 1]
        node.instance_variable_set(:@composition_anchor, anchor)
        node.instance_variable_set(:@composition_path, prefix + [anchor.last])
      end

      source_groups.each_with_index do |old_node, index|
        old_anchor = old_anchors[index]
        next unless old_anchor

        anchor_map[old_anchor] =
          prepared_groups[index].instance_variable_get(:@composition_anchor)
      end

      anchor_map
    end

    def assign_references(nodes, root_call, anchor_map)
      groups = captures(nodes)
      by_anchor = groups.each_with_object({}) { |group, map| map[group.instance_variable_get(:@composition_anchor)] = group }
      raw_anchor_by_order = {}
      unless anchor_map.any?
        groups.reject do |group|
          group.instance_variable_get(:@composition_synthetic_root)
        end.each_with_index do |group, index|
          raw_anchor_by_order[index + 1] = group.instance_variable_get(:@composition_anchor)
        end
      end
      structural_nodes(nodes) do |node, _path|
        next unless referrer?(node)
        old_targets = node.instance_variable_get(:@composition_target_paths)
        if old_targets
          targets = old_targets.map do |target|
            if target == :root
              by_anchor[:root]
            else
              new_anchor = anchor_map[target] || raw_anchor_by_order[target.last.to_i]
              by_anchor[new_anchor]
            end
          end
          set_target_paths(node, targets)
        else
          set_original_target(node, groups)
        end
        if node.is_a?(Regexp::Expression::Backreference::NameCall) && node.instance_variable_get(:@composition_target_paths).length > 1
          raise CompositionError.new(%q{cannot call a multiplex named capture}, [node.text])
        end
      end
      return unless root_call
      structural_nodes(nodes) do |node, _path|
        next unless node.is_a?(Regexp::Expression::Backreference::NumberCall) && node.number.zero?
        node.instance_variable_set(:@composition_target_paths, [:root])
        node.instance_variable_set(:@composition_synthetic_root_target, true)
      end
    end

    def captures(nodes)
      groups = []
      structural_nodes(nodes) { |node, _path| groups << node if node.is_a?(Regexp::Expression::Group::Capture) }
      groups
    end

    def set_original_target(node, groups)
      if name_reference?(node)
        targets = groups.select { |group| group_name(group) == node.reference }
      else
        number = reference_number(node)
        return if number.zero?
        targets = groups.select { |group| group.instance_variable_get(:@composition_old_number) == number }
      end
      set_target_paths(node, targets)
    end

    def set_target_paths(node, paths)
      if paths.empty?
        raise CompositionError.new("invalid capture reference #{node.reference.inspect}",
                                  [node.text])
      end
      node.instance_variable_set(:@composition_target_paths,
        paths.map { |path| path.respond_to?(:instance_variable_get) ? path.instance_variable_get(:@composition_anchor) : path })
    end

    def reference_number(node)
      if node.is_a?(Regexp::Expression::Backreference::NumberRelative)
        node.effective_number
      elsif node.is_a?(Regexp::Expression::Conditional::Condition)
        node.reference.is_a?(Integer) ? node.reference : 0
      else
        node.number
      end
    end

    def group_name(group)
      if group.instance_of?(Regexp::Expression::Group::Named)
        group.name
      else
        group.instance_variable_get(:@composition_generated_name)
      end
    end

    def target_name(group)
      group.respond_to?(:name) ? group.name : group.instance_variable_get(:@composition_generated_name)
    end

    def referrer?(node)
      node.is_a?(Regexp::Expression::Backreference::Base) ||
        node.is_a?(Regexp::Expression::Conditional::Condition)
    end

    def name_reference?(node)
      (node.is_a?(Regexp::Expression::Conditional::Condition) &&
        node.reference.is_a?(String)) ||
        node.is_a?(Regexp::Expression::Backreference::Name)
    end

    def root_call?(root)
      call = nil
      structural_nodes([root]) do |node, _path|
        if node.is_a?(Regexp::Expression::Backreference::NumberCall) && node.number.zero?
          call = node
        end
      end
      call
    end

    def passive_group
      Regexp::Expression::Group::Passive.construct(text: '(?:', token: :passive)
    end

    def quantifier_expression(quantifier, mode)
      return quantifier.dup if quantifier.is_a?(Regexp::Expression::Quantifier)

      text = quantifier.to_s
      token =
        case text[0]
        when '?' then :zero_or_one
        when '*' then :zero_or_more
        when '+' then :one_or_more
        else :interval
        end
      if mode
        suffix = { greedy: '', reluctant: '?', possessive: '+' }.fetch(mode) do
          raise ArgumentError, "unknown quantifier mode #{mode.inspect}"
        end
        text = text + suffix unless text =~ /[?+]\z/
      end
      Regexp::Expression::Quantifier.construct(text: text, token: token)
    end

    def finalize(root, _prepared, policy)
      unless %i[raise rename keep].include?(policy)
        raise ArgumentError, "unknown name conflict policy #{policy.inspect}"
      end

      groups = recalculate_captures(root)
      rename_captures(groups, policy)
      force_name = groups.any? { |group| group.instance_of?(Regexp::Expression::Group::Named) }
      if force_name
        name_all_captures(groups)
        groups = recalculate_captures(root)
      end
      rewrite_references(root, groups, force_name)
      update_levels(root)
      root.assign_referenced_expressions
      root.recursively_update_nesting_levels
      map = CaptureMap.new(build_capture_map(groups))
      root.instance_variable_set(:@composition_capture_map, map)
      root
    end

    def recalculate_captures(root)
      groups = []
      counters = Hash.new(0)
      number = 0
      structural_nodes([root]) do |node, path|
        next unless node.is_a?(Regexp::Expression::Group::Capture)

        number += 1
        node.number = number
        key = passive_ancestor(node, root)
        node.number_at_level = (counters[key] += 1)
        node.instance_variable_set(:@composition_path, path) unless node.instance_variable_get(:@composition_synthetic_root)
        groups << node
      end
      groups
    end

    def passive_ancestor(node, root)
      ancestor = node.parent
      while ancestor && !ancestor.equal?(root)
        return ancestor if ancestor.is_a?(Regexp::Expression::Group::Passive) ||
                          ancestor.is_a?(Regexp::Expression::Group::Options)

        ancestor = ancestor.parent
      end
      root
    end

    def rename_captures(groups, policy)
      named = groups.select { |group| group.instance_of?(Regexp::Expression::Group::Named) }
      conflicting_names = named.map(&:name).select do |name|
        named.count { |group| group.name == name } > 1
      end.uniq
      return if conflicting_names.empty? || policy == :keep

      conflicting_names.each do |name|
        if policy == :raise
          paths = named.select { |group| group.name == name }.map do |group|
            group.instance_variable_get(:@composition_path)
          end
          raise CompositionError.new("capture name conflict #{name.inspect} at #{paths.inspect}")
        end

        scoped = named.select { |group| group.name == name }.group_by do |group|
          group.instance_variable_get(:@composition_scope) ||
            [group.instance_variable_get(:@composition_path), name]
        end
        used = named.map(&:name)
        scoped.values.each_with_index do |scope_groups, index|
          new_name = unique_name(name, scope_groups.first, index, used)
          scope_groups.each { |group| change_named_capture(group, new_name) }
          used << new_name
        end
      end
    end

    def unique_name(name, group, index, used)
      path = group.instance_variable_get(:@composition_path)
      base = "c#{path.map(&:to_s).join('_')}_#{sanitize_name(name)}"
      candidate = index.zero? ? base : "#{base}_#{index + 1}"
      candidate = "#{candidate}_#{index + 1}" while used.include?(candidate)
      candidate
    end

    def sanitize_name(name)
      result = name.gsub(/[^0-9A-Za-z_]/, '_')
      result = "c_#{result}" if result.empty? || result =~ /\A[0-9]/
      result
    end

    def change_named_capture(group, new_name)
      delimiter = group.text.start_with?("(?'") ? "'" : '<'
      closing = delimiter == "'" ? "'" : '>'
      group.text = "(?#{delimiter}#{new_name}#{closing}"
      group.instance_variable_set(:@name, new_name)
    end

    def name_all_captures(groups)
      used = groups.map { |group| target_name(group) }.compact
      groups.each do |group|
        next if group.instance_of?(Regexp::Expression::Group::Named)

        path = group.instance_variable_get(:@composition_path) || []
        base = "c#{path.map(&:to_s).join('_')}"
        name = base
        index = 1
        while used.include?(name)
          name = "#{base}_#{index += 1}"
        end
        used << name
        group.text = "(?<#{name}>"
        group.instance_variable_set(:@composition_generated_name, name)
        replace_group(group, name)
      end
    end

    def replace_group(group, name)
      named = Regexp::Expression::Group::Named.construct(
        type: group.type, token: :named, text: "(?<#{name}>", ts: group.ts,
        te: group.te, level: group.level, set_level: group.set_level,
        conditional_level: group.conditional_level, options: group.options)
      named.number = group.number
      named.number_at_level = group.number_at_level
      named.quantifier = group.quantifier
      %i[@composition_identity @composition_old_number @composition_old_name
         @composition_anchor @composition_path @composition_generated_name].each do |ivar|
        named.instance_variable_set(ivar, group.instance_variable_get(ivar))
      end
      group.parent.expressions[group.parent.expressions.index { |expression| expression.equal?(group) }] = named
      children = group.expressions.dup
      children.each { |child| child.parent = named }
      children.each { |child| named << child }
      named
    end

    def rewrite_references(root, groups, force_name = false)
      by_anchor = {}
      groups.each { |group| by_anchor[group.instance_variable_get(:@composition_anchor)] = group }

      referrers = []
      structural_nodes([root]) do |node, _path|
        referrers << node if referrer?(node)
      end
      # Synthetic root groups contain the actual whole-pattern calls.
      synthetic = groups.select { |group| group.instance_variable_get(:@composition_synthetic_root) }
      synthetic.each do |group|
        by_anchor[group.instance_variable_get(:@composition_anchor)] = group
      end

      referrers.uniq.each do |node|
        paths = node.instance_variable_get(:@composition_target_paths) || next
        targets = paths.map { |anchor| by_anchor[anchor] }.compact
        raise CompositionError.new("unresolved capture reference #{node.reference.inspect}",
                                  [node.text]) if targets.empty?
        rewrite_reference(node, targets, force_name)
      end
    end

    def rewrite_reference(node, targets, force_name)
      names = targets.map { |target| target_name(target) }.compact.uniq
      if names.length == 1 && (!numeric_kind?(node) || targets.length == 1)
        rewrite_named_reference(node, names.first, targets.first)
      elsif targets.length == 1
        rewrite_number_reference(node, targets.first.number, targets.first, force_name)
      else
        raise CompositionError.new("ambiguous capture reference #{node.reference.inspect}",
                                  [node.text])
      end
    end

    def numeric_kind?(node)
      node.is_a?(Regexp::Expression::Backreference::Number) ||
        node.is_a?(Regexp::Expression::Conditional::Condition) && node.reference.is_a?(Integer)
    end

    def rewrite_named_reference(node, name, target)
      if node.is_a?(Regexp::Expression::Conditional::Condition)
        node.text = "(<#{name}>)"
      elsif node.is_a?(Regexp::Expression::Backreference::NameRecursionLevel)
        node.text = "\\k<#{name}#{signed(node.recursion_level)}>"
        node.instance_variable_set(:@name, name)
      elsif node.is_a?(Regexp::Expression::Backreference::NameCall)
        node.text = "\\g<#{name}>"
        node.instance_variable_set(:@name, name)
      else
        delimiter = node.text =~ /\A\\k'/ ? "'" : '<'
        closing = delimiter == "'" ? "'" : '>'
      node.text = "\\k#{delimiter}#{name}#{closing}"
      node.instance_variable_set(:@name, name)
      end
    end

    def rewrite_number_reference(node, number, target, force_name)
      if node.is_a?(Regexp::Expression::Conditional::Condition)
        if force_name
          ensure_named_capture(target)
          node.text = "(<#{target_name(target)}>)"
        else
          node.text = "(#{number})"
        end
      elsif node.is_a?(Regexp::Expression::Backreference::NumberRecursionLevel)
        if force_name
          ensure_named_capture(target)
          node.text = "\\k<#{target_name(target)}#{signed(node.recursion_level)}>"
          node.instance_variable_set(:@name, target_name(target))
        else
          node.text = "\\k<#{number}#{signed(node.recursion_level)}>"
          set_reference_number(node, number)
        end
      elsif node.is_a?(Regexp::Expression::Backreference::NumberCall) ||
            node.is_a?(Regexp::Expression::Backreference::NumberCallRelative)
        if force_name
          ensure_named_capture(target)
          node.text = "\\g<#{target_name(target)}>"
          node.instance_variable_set(:@name, target_name(target))
        else
          node.text = "\\g<#{number}>"
          set_reference_number(node, number)
        end
      elsif node.text.start_with?('\\k')
        delimiter = node.text =~ /\A\\k'/ ? "'" : '<'
        closing = delimiter == "'" ? "'" : '>'
        if force_name
          ensure_named_capture(target)
          node.text = "\\k#{delimiter}#{target_name(target)}#{closing}"
          node.instance_variable_set(:@name, target_name(target))
        else
          node.text = "\\k#{delimiter}#{number}#{closing}"
          set_reference_number(node, number)
        end
      else
        if force_name
          ensure_named_capture(target)
          node.text = "\\k<#{target_name(target)}>"
          node.instance_variable_set(:@name, target_name(target))
        else
          node.text = "\\#{number}"
        end
      end
      node.effective_number = number if node.is_a?(Regexp::Expression::Backreference::NumberRelative)
    end

    def set_reference_number(node, number)
      node.instance_variable_set(:@number, number)
    end

    def ensure_named_capture(group)
      target_name(group)
    end

    def signed(number)
      number >= 0 ? format('%+d', number) : number.to_s
    end

    def build_capture_map(groups)
      groups.reject do |group|
        group.instance_variable_get(:@composition_synthetic_root)
      end.map do |group|
        current_name = group_name(group)
        current_name = nil if group.instance_variable_get(:@composition_generated_name)
        MappedCapture.new(
          group.instance_variable_get(:@composition_identity),
          group.instance_variable_get(:@composition_old_number),
          group.instance_variable_get(:@composition_old_name),
          group.number,
          current_name,
          group.instance_variable_get(:@composition_path)
        )
      end
    end

    def update_levels(root)
      root.level = 0
      stack = root.expressions.reverse.map { |node| [node, 0, 0, 0, :enter] }
      until stack.empty?
        node, group_depth, set_depth, conditional_depth, event = stack.pop
        if event == :exit
          next
        end

        node.conditional_level = conditional_depth if node.respond_to?(:conditional_level=)
        node.set_level = set_depth if node.respond_to?(:set_level=)
        node.level = group_depth unless node.is_a?(Regexp::Expression::Root)
        node.quantifier.level = group_depth if node.quantifier

        next if node.terminal?

        if node.is_a?(Regexp::Expression::Conditional::Expression)
          conditional_depth += 1
        end
        if node.is_a?(Regexp::Expression::CharacterSet)
          set_depth += 1
        elsif node.is_a?(Regexp::Expression::Group::Base)
          group_depth += 1
        end

        stack.push([node, group_depth, set_depth, conditional_depth, :exit])
        node.expressions.reverse_each do |child|
          stack.push([child, group_depth, set_depth, conditional_depth, :enter])
        end
      end
    end

    def structural_nodes(nodes)
      stack = Array(nodes).reverse.map { |node| [node, []] }
      until stack.empty?
        node, path = stack.pop
        yield(node, path)
        next if node.terminal?

        node.expressions.reverse_each.with_index do |child, index|
          reverse_index = node.expressions.length - index - 1
          stack.push([child, path + [reverse_index]])
        end
      end
    end
  end
end
