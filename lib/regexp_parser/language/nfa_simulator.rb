# frozen_string_literal: true

class Regexp::Parser
  module Language
    # Exact simulation of one gated NFA over an explicit alphabet.
    #
    # A configuration is a tuple [u, l, p, pre] where
    # * +u+   - unlocked states,
    # * +l+   - states locked behind a \Z edge (one final newline allowed),
    # * +p+   - states after consuming that locked final newline,
    # * +pre+ - unlocked states immediately before the last consumed
    #   character, used to evaluate Ruby's trailing-newline tolerance.
    class NfaSimulator
    NEWLINE = "\n".freeze

    def initialize(nfa)
      @nfa = nfa
    end

    def start
      closure(bit(@nfa.start), 0, 0, at_start: true) + [0]
    end

    # Advance one character; returns the new configuration tuple.
    def advance(config, char, previous_newline)
      u, l, p, previous_pre = config
      is_newline = char == NEWLINE
      ready_u = consume_closure(u, is_newline, true)
      ready_l = is_newline ? consume_closure(l, is_newline, false) : 0
      raw_u = consume(ready_u, char)
      raw_l = is_newline ? consume(ready_l, char) : 0
      walked = closure(raw_u, raw_l, 0,
                        prev_newline: previous_newline,
                        before_newline_consume: is_newline)
      walked[2] |= p
      # When consuming a newline, remember the configuration immediately
      # before it (Ruby lets a trailing $/\Z drop that final newline).
      pre = is_newline ? ready_u : previous_pre
      walked + [pre]
    end

    # Whether the configuration accepts the word built so far.
    def accept?(config, previous_newline)
      u, l, p, pre = config
      end_bits = closure(u, 0, 0, at_end: true, prev_newline: previous_newline)
      return true if end_bits[0] & bit(@nfa.accept) != 0
      return true if locked_accept?(l, p)
      return true if @nfa.trailing_tolerant && previous_newline &&
        trailing_newline_accept?(pre)
      false
    end

    # Acceptance of a word formed by appending one final newline to the word
    # represented by the current configuration.
    def accept_with_final_newline?(config)
      return false unless @nfa.trailing_tolerant
      trailing_newline_accept?(config[3]) ||
        locked_newline_accept?(config[1])
    end

    private

    def locked_accept?(locked, passed)
      return true if locked & bit(@nfa.accept) != 0
      return true if passed & bit(@nfa.accept) != 0
      closed = closure(0, locked, 0, at_end: true)
      closed[1] & bit(@nfa.accept) != 0
    end

    def locked_newline_accept?(locked)
      # \Z path consuming its one allowed newline
      raw = consume(locked, NEWLINE)
      return false if raw == 0
      closed = closure(raw, 0, 0, prev_newline: false)
      closed[0] & bit(@nfa.accept) != 0 || closed[1] & bit(@nfa.accept) != 0
    end

    def trailing_newline_accept?(pre)
      reached = 0
      worklist = bits_to_states(pre)
      until worklist.empty?
        state = worklist.shift
        next if reached & bit(state) != 0
        reached |= bit(state)
        @nfa.outgoing(state).each do |edge|
          case edge.kind
          when :plain
            worklist << edge.to if reached & bit(edge.to) == 0
          when :endline, :eol, :Z
            gated = gate_tail_closure(edge.to)
            return true if gated & bit(@nfa.accept) != 0
          end
        end
      end
      false
    end

    def gate_tail_closure(initial)
      result = 0
      worklist = [initial]
      until worklist.empty?
        state = worklist.shift
        next if result & bit(state) != 0
        result |= bit(state)
        @nfa.outgoing(state).each do |edge|
          next unless edge.kind == :plain || edge.kind == :z ||
            edge.kind == :endline || edge.kind == :eol
          worklist << edge.to if result & bit(edge.to) == 0
        end
      end
      result
    end

    # Epsilon closure with position-dependent gates.
    def closure(initial_u, initial_l, initial_p, context)
      at_start = context.fetch(:at_start, false)
      at_end = context.fetch(:at_end, false)
      prev_newline = context.fetch(:prev_newline, false)
      before_consume = context.fetch(:before_newline_consume, false)
      u = 0
      l = 0
      p = 0
      work = []
      bits_to_states(initial_u).each { |s| work << [s, :u] }
      bits_to_states(initial_l).each { |s| work << [s, :l] }
      bits_to_states(initial_p).each { |s| work << [s, :p] }
      until work.empty?
        state, family = work.shift
        if family == :u
          next if u & bit(state) != 0
          u |= bit(state)
        elsif family == :l
          next if l & bit(state) != 0
          l |= bit(state)
        else
          next if p & bit(state) != 0
          p |= bit(state)
        end
        @nfa.outgoing(state).each do |edge|
          target = gate_family(edge.kind, family, at_start, at_end,
                               prev_newline, before_consume)
          next unless target
          target_bits = target == :u ? u : target == :l ? l : p
          next if target_bits & bit(edge.to) != 0
          work << [edge.to, target]
        end
      end
      [u, l, p]
    end

    def gate_family(kind, family, at_start, at_end, prev_newline, before_consume)
      case kind
      when :plain
        family
      when :bos, :endline
        if family == :u
          start_gate = kind == :bos
          position_ok = start_gate ? at_start :
            (at_end || prev_newline || before_consume)
          :u if position_ok
        end
      when :bol
        if family != :p && (at_start || prev_newline)
          family
        end
      when :eol
        if family == :u && (at_end || prev_newline || before_consume)
          :u
        end
      when :Z
        if family == :u && (at_end || prev_newline || before_consume)
          :l
        end
      when :z
        :u if family == :u && at_end
      end
    end

    def consume_closure(bits, is_newline, _unlocked)
      closure(bits, 0, 0, at_start: true,
              before_newline_consume: is_newline)[0]
    end

    def consume(bits, char)
      result = 0
      bits_to_states(bits).each do |state|
        @nfa.outgoing(state).each do |edge|
          next unless edge.kind == :char
          result |= bit(edge.to) if edge.labels.include?(char)
        end
      end
      result
    end

    def bit(state)
      1 << state
    end

    def bits_to_states(bits)
      states = []
      index = 0
      until bits == 0
        states << index if bits & 1 == 1
        bits >>= 1
        index += 1
      end
      states
    end
    end
  end
end
