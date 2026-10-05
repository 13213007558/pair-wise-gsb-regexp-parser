# frozen_string_literal: true

class Regexp::Parser
  module Language
    class NFA
      class StateLimit < StandardError
        def initialize(limit)
          super "language automaton exceeds #{limit} states"
        end
      end

      class Fragment
        attr_accessor :start, :accept

        def initialize(start, accept)
          @start = start
          @accept = accept
        end
      end

      attr_reader :states, :state_count, :state_limit

      def initialize(state_limit)
        @states = {}
        @state_count = 0
        @state_limit = state_limit
      end

      def state
        id = @state_count
        raise StateLimit.new(@state_limit) if id >= @state_limit
        @state_count += 1
        @states[id] = {
          epsilon: Set.new,
          start: Set.new,
          end_boundary: Set.new,
          char: Hash.new { |hash, key| hash[key] = Set.new }
        }
        id
      end

      def fragment
        Fragment.new(state, state)
      end

      def epsilon(from, to)
        @states.fetch(from)[:epsilon] << to
      end

      def char(from, string, to)
        @states.fetch(from)[:char][string] << to
      end

      def start_boundary(from, type, to)
        @states.fetch(from)[:start] << [type, to]
      end

      def end_boundary(from, type, to)
        @states.fetch(from)[:end_boundary] << [type, to]
      end

      def concatenate(fragments)
        result = Fragment.new(state, state)
        if fragments.empty?
          epsilon(result.start, result.accept)
        else
          result.start = fragments.first.start
          result.accept = fragments.last.accept
          fragments.each_cons(2) do |left, right|
            epsilon(left.accept, right.start)
          end
        end
        result
      end

      def union(fragments)
        result = Fragment.new(state, state)

        fragments.each do |fragment|
          epsilon(result.start, fragment.start)
          epsilon(fragment.accept, result.accept)
        end

        result
      end

      def repeat(fragment, min, max)
        base = copy(fragment)
        copies = Array.new(min) { copy(base) }
        result =
          if copies.empty?
            result = Fragment.new(state, state)
            epsilon(result.start, result.accept)
            result
          else
            concatenate(copies)
          end

        if max.nil?
          repeated = copy(base)
          epsilon(result.accept, repeated.start)
          epsilon(repeated.accept, repeated.start)
          epsilon(repeated.accept, result.accept)
        elsif max > min
          (min...max).each do
            optional = copy(base)
            split = state
            join = state
            epsilon(result.accept, split)
            epsilon(split, optional.start)
            epsilon(split, join)
            epsilon(optional.accept, join)
            result.accept = join
          end
        end

        result
      end

      def copy(fragment)
        reachable = reachable_states(fragment.start)
        mapping = {}
        reachable.each { |id| mapping[id] = state }

        reachable.each do |id|
          source = @states.fetch(id)
          target = @states.fetch(mapping.fetch(id))
          target[:epsilon].merge(
            source[:epsilon].map { |next_id| mapping.fetch(next_id) }
          )
          source[:start].each do |type, next_id|
            start_boundary(mapping.fetch(id), type, mapping.fetch(next_id))
          end
          source[:end_boundary].each do |type, next_id|
            end_boundary(mapping.fetch(id), type, mapping.fetch(next_id))
          end
          source[:char].each do |string, next_states|
            next_states.each do |next_id|
              char(mapping.fetch(id), string, mapping.fetch(next_id))
            end
          end
        end

        Fragment.new(mapping.fetch(fragment.start), mapping.fetch(fragment.accept))
      end

      def reachable_states(start)
        seen = Set.new
        pending = [start]

        until pending.empty?
          id = pending.pop
          next unless seen.add?(id)
          state = @states.fetch(id)
          pending.concat(state[:epsilon].to_a)
          pending.concat(state[:start].map { |edge| edge[1] })
          pending.concat(state[:end_boundary].map { |edge| edge[1] })
          state[:char].each_value do |next_states|
            pending.concat(next_states.to_a)
          end
        end

        seen
      end
    end
  end
end
