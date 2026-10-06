# frozen_string_literal: true

class Regexp::Parser
  class FiniteLanguage
    # @api private
    #
    # Length-indexed determinization over the epsilon NFA. DP states are sets
    # of NFA states (bitmasks). Summing over alphabet characters counts each
    # distinct string once: the determinization merges every syntax path
    # that ends in the same NFA configuration for the same consumed prefix.
    class Engine
      Context = Struct.new(:at_start, :after_nl, :remaining, :total) do
        def line_start?
          at_start || after_nl
        end
      end

      def initialize(language, budget)
        @language = language
        @budget = budget
        @alphabet = language.alphabet
        @states, @nfa_start, = language.build_nfa(budget: budget)
        @memo = {}
        @transition_memo = {}
        @closure_memo = {}
      end

      def count(n)
        ctx = Context.new(true, false, n, n)
        f(n, initial_closure(ctx), ctx)
      end

      def nth(n, rank)
        set, ctx, chars = prepare(n)
        total = f(n, set, ctx)
        raise InvalidQuery, "rank #{rank} is out of range (0...#{total})" if rank >= total

        walk(n, set, ctx, chars) do |entries, rem|
          chosen = nil
          entries.each do |entry|
            weight = f(rem - 1, entry[:target], entry[:context])
            if rank < weight
              chosen = entry
              break
            end
            rank -= weight
          end
          raise InvalidQuery, 'rank out of range' unless chosen

          chosen
        end
      end

      def sample(n, random)
        set, ctx, chars = prepare(n)
        total = f(n, set, ctx)
        raise InvalidQuery, 'cannot sample from an empty language' if total.zero?

        rank = random.rand(total)
        walk(n, set, ctx, chars) do |entries, rem|
          chosen = nil
          entries.each do |entry|
            weight = f(rem - 1, entry[:target], entry[:context])
            if rank < weight
              chosen = entry
              break
            end
            rank -= weight
          end
          raise InvalidQuery, 'sampling failed' unless chosen

          chosen
        end
      end

      private

      def prepare(n)
        ctx = Context.new(true, false, n, n)
        set = initial_closure(ctx)
        total = f(n, set, ctx)
        raise InvalidQuery, "language has no strings of length #{n}" if total.zero?

        [set, ctx, []]
      end

      def walk(n, set, ctx, chars)
        current = set
        current_ctx = ctx
        n.times do |consumed|
          entries = transitions(current, current_ctx)
          chosen = yield(entries, n - consumed)
          chars << chosen[:char]
          current = chosen[:target]
          current_ctx = chosen[:context]
        end
        chars.join
      end

      def initial_closure(ctx)
        closure(bit(@nfa_start.id), ctx)
      end

      def spend
        @budget -= 1
        raise BudgetExhausted, 'counting exceeded budget' if @budget.negative?
      end

      # Number of distinct completable strings for +remaining+ characters.
      def f(remaining, set, ctx)
        key = [remaining, set, ctx.after_nl, ctx.at_start]
        return @memo[key] if @memo.key?(key)

        spend
        value =
          if remaining.zero?
            accepting?(set) ? 1 : 0
          else
            transitions(set, ctx).sum(0) do |entry|
              f(remaining - 1, entry[:target], entry[:context])
            end
          end
        @memo[key] = value
      end

      # One entry per alphabet character with at least one continuation.
      def transitions(set, ctx)
        key = [set, ctx.remaining, ctx.after_nl, ctx.at_start]
        return @transition_memo[key] if @transition_memo.key?(key)

        spend
        edges = []
        each_state(set) { |state| edges.concat(state.ch_edges) }
        entries = []
        @alphabet.each do |char|
          destination = 0
          edges.each do |atom, target|
            if atom.is_a?(FiniteLanguage::ZeroWidthNewlineAtom) &&
               ctx.remaining == ctx.total
              next
            end
            destination |= bit(target.id) if @language.matcher_for(atom).match?(char)
          end
          next if destination.zero?

          next_ctx = Context.new(false, char == "\n", ctx.remaining - 1, ctx.total)
          entries << { char: char, target: closure(destination, next_ctx),
                       context: next_ctx }
        end
        @transition_memo[key] = entries
      end

      def accepting?(set)
        each_state(set).any?(&:final)
      end

      def each_state(set)
        return enum_for(:each_state, set) unless block_given?

        @states.each { |state| yield state if set[state.id] == 1 }
      end

      def bit(id)
        1 << id
      end

      # Epsilon closure with positional anchor gates.
      def closure(bits, ctx)
        key = [bits, ctx.at_start, ctx.after_nl, ctx.remaining]
        return @closure_memo[key] if @closure_memo.key?(key)

        spend
        seen = bits
        queue = []
        each_state(bits) { |state| queue << state }
        until queue.empty?
          state = queue.shift
          state.eps.each do |target|
            next if (seen & bit(target.id)) != 0

            seen |= bit(target.id)
            queue << target
          end
          if ctx.line_start?
            state.start_gates.each do |target|
              next if (seen & bit(target.id)) != 0

              seen |= bit(target.id)
              queue << target
            end
          end
          next unless ctx.remaining.zero?

          (state.strict_end_gates + state.loose_end_gates.map(&:first)).each do |target|
            next if (seen & bit(target.id)) != 0

            seen |= bit(target.id)
            queue << target
          end
        end
        @closure_memo[key] = seen
      end
    end
  end
end
