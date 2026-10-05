# frozen_string_literal: true

class Regexp::Parser
  module Language
    # A Thompson-style epsilon NFA with special, gated epsilon edges for the
    # supported anchors.
    #
    # Edge kinds:
    # * +:char+  - labeled edge; +labels+ holds the alphabet characters it
    #   accepts
    # * +:plain+ - ordinary epsilon
    # * +:bos+   - \A or \G; passable only at position 0
    # * +:bol+   - ^; passable at position 0 or after a line break (m mode)
    # * +:eol+   - $; passable before a line break or the end (m mode plus
    #   the final position)
    # * +:endline+ - a non-multiline $; end, or before the final newline
    # * +:Z+     - \Z; end, or before exactly one final line break
    # * +:z+     - \z; end only
    class NFA
      attr_accessor :start, :accept
      attr_accessor :finite, :max_length, :multiline, :trailing_tolerant
      attr_reader :edges, :state_count

      def initialize
        @edges = Hash.new { |hash, key| hash[key] = [] }
        @state_count = 0
        @finite = true
        @max_length = 0
        @multiline = false
        @trailing_tolerant = false
      end

      def add_state
        @state_count += 1
        @state_count - 1
      end

      def add_edge(from, to, kind = :plain, labels = nil)
        @edges[from] << Edge.new(to, kind, labels)
      end

      def outgoing(state)
        @edges[state]
      end

      Edge = Struct.new(:to, :kind, :labels) do
        def epsilon?
          kind == :plain
        end
      end

      Fragment = Struct.new(:start, :accept, :states, :finite, :max_length)
    end
  end
end

