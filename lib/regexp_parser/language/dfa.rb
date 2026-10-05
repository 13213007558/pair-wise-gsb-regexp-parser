# frozen_string_literal: true

require 'set'

class Regexp::Parser
  module Language
    class DFA
      StateLimit = Class.new(StandardError)
      NEWLINE = "\n".freeze

      def self.build(nfa:, start:, accept:, prefix_loop:, pattern_accept:, alphabet:, state_limit:)
        new(nfa, start, accept, prefix_loop, pattern_accept, alphabet, state_limit).build
      end

      def initialize(nfa, start, accept, prefix_loop, pattern_accept, alphabet, limit)
        @nfa, @accept, @prefix_loop, @pattern_accept = nfa, accept, prefix_loop, pattern_accept
        @alphabet, @limit = alphabet, limit
        @states = {}
        initial = key(core_closure([start], :bos), [])
        state_id(initial)
        @initial = initial
      end

      def build
        pending = [@initial]
        until pending.empty?
          current = pending.pop
          next if @states[current][:built]
          transitions = {}
          core, locked = current

          @alphabet.each do |char|
          if char == NEWLINE
              destination = core_step(core, char, :nl, true)
              line_locked = boundary_lock(core, :line)
              final_locked = boundary_lock(core, :final)
              restart = cross_line_start(core)
              destination = core_closure(destination + restart, :nl)
              next_locked = locked_step(locked, char) + line_locked
              transitions[[:char, char]] = key(destination, next_locked)
              transitions[:terminal_newline] = key([], final_locked)
          else
              destination = core_step(core, char, char, false)
              next_locked = locked_step(locked, char)
              add_unanchored_locks(core, char, destination, next_locked)
              transitions[[:char, char]] = key(destination, next_locked)
          end
          end

          @states[current].merge!(built: true, transitions: transitions, accepting: accepting?(current))
          transitions.each_value do |next_key|
            next if @states.key?(next_key)
            state_id(next_key)
            pending << next_key
          end
        end

        dead = key([], [])
        state_id(dead) unless @states.key?(dead)
        @states[dead].merge!(built: true, transitions: {})
        { initial: 0, accept: accept_ids, states: @states, dead: @states[dead][:id] }
      end

      private

      def core_step(core, char, previous, keep_boundary)
        targets = move(core, char)
        core_closure(targets, previous)
      end

      def locked_step(locked, char)
        return [] unless locked.include?(@accept)
        targets = []
        @nfa.states[@accept][:char].fetch(char, Set.new).each { |target| targets << target }
        epsilon_closure(targets)
      end

      def add_unanchored_locks(core, char, destination, locked)
        core.each do |state|
          next if boundary?(state)
          targets = @nfa.states[state][:char].fetch(char, Set.new)
          targets.each do |target|
          closure = epsilon_closure([target])
            if closure.include?(@pattern_accept)
              locked << @accept
            end
          end
        end
        destination.each do |state|
          next if boundary?(state)
          closure = epsilon_closure([state])
          locked << @accept if closure.include?(@pattern_accept)
        end
      end

      def boundary_lock(core, mode)
        locked = []
        reachable_end_targets(core, mode).each do |target|
          closure = epsilon_closure([target])
          locked.concat(closure) if closure.include?(@accept)
        end
        locked.uniq
      end

      def cross_line_start(core)
        states = []
        reachable_end_targets(core, :line).each do |target|
          closure = epsilon_closure([target])
          next if closure.include?(@accept)
          @nfa.states[target][:start].each do |type, next_state|
            states << next_state if type == :line
          end
        end
        states
      end

      def move(states, char)
        states.each_with_object([]) do |state, targets|
          next if boundary?(state)
          @nfa.states[state][:char].fetch(char, Set.new).each { |target| targets << target }
        end.uniq
      end

      def end_targets(core, mode)
        core.each_with_object([]) do |state, targets|
          next if state == @prefix_loop
          @nfa.states[state][:end_boundary].each do |type, target|
            targets << target if allowed_end?(type, mode)
          end
        end.uniq
      end

      def reachable_end_targets(core, mode)
        epsilon_closure(core).each_with_object([]) do |state, targets|
          next if state == @prefix_loop
          @nfa.states[state][:end_boundary].each do |type, target|
            targets << target if allowed_end?(type, mode)
          end
        end.uniq
      end

      def core_closure(states, previous = nil)
        traverse(states) do |state, seen, pending|
          @nfa.states[state][:start].each do |type, target|
            if allowed_start?(type, previous) && seen.add?(target)
              pending << target
            end
          end
        end
      end

      def epsilon_closure(states)
        traverse(states)
      end

      def traverse(states)
        seen = states.is_a?(Set) ? states.dup : Set.new(states)
        pending = seen.to_a
        while (state = pending.pop)
          yield(state, seen, pending) if block_given?
          @nfa.states[state][:epsilon].each do |target|
            pending << target if seen.add?(target)
          end
        end
        seen.to_a
      end

      def boundary?(state)
        @nfa.states[state][:end_boundary].any?
      end

      def allowed_start?(type, previous)
        return previous == :bos if type == :bos
        previous == :bos || previous == :nl
      end

      def allowed_end?(type, mode)
        return true if mode == :line || mode == :all
        type == :line_end || type == :eos_or_final_newline
      end

      def accepting?(key)
        core, locked = key
        locked.include?(@accept) ||
          end_targets(core, :all).any? { |target| epsilon_closure([target]).include?(@accept) }
      end

      def key(core, locked)
        [Set.new(core).freeze, Set.new(locked).freeze].freeze
      end

      def state_id(key)
        id = @states.length
        raise StateLimit, "language automaton exceeds #{@limit} states" if id >= @limit
        @states[key] = { id: id, built: false, accepting: accepting?(key) }
        id
      end

      def accept_ids
        @states.select { |_key, state| state[:accepting] }.map { |_key, state| state[:id] }
      end
    end
  end
end
