# frozen_string_literal: true

class Regexp::Parser
  class FiniteLanguage
    # A char matcher wraps a parser fragment so that
    # <tt>Regexp.new("\\A#{fragment}\\z")</tt> matches exactly one character.
    Atom = Struct.new(:source, :options, :literal, keyword_init: true) do
      def cache_key
        [source, options[:i], options[:m], options[:d], options[:u], literal]
      end

      def build_matcher
        body = literal ? Regexp.escape(source) : source
        flags = String.new
        flags << 'i' if options[:i]
        flags << 'm' if options[:m]
        fragment = flags.empty? ? "(?:#{body})" : "(?#{flags}:#{body})"
        Regexp.new("\\A#{fragment}\\z", options[:d] ? Regexp::NOENCODING : nil)
      end
    end

    # Node of a Thompson-style epsilon NFA.
    # * +eps+ - always-traversable epsilon edges
    # * +start_gates+ - \A, \G and (non-multiline) ^ edges, open at position
    #   0 or right after a newline
    # * +strict_end_gates+ - \z edges, open only when no characters remain
    # * +loose_end_gates+ - $ and \Z edges; pairs [target, terminal]. A
    #   terminal gate (the anchor is the last top-level token) additionally
    #   gets a trailing-newline edge (see TerminalNewlineAtom).
    # * +ch_edges+ - [atom, target] pairs consuming one character
    State = Struct.new(:id, :eps, :start_gates, :strict_end_gates,
                       :loose_end_gates, :ch_edges, :final,
                       keyword_init: true) do
      def initialize(id:)
        super(id: id, eps: [], start_gates: [], strict_end_gates: [],
               loose_end_gates: [], ch_edges: [], final: false)
      end
    end

    Fragment = Struct.new(:start, :accept, keyword_init: true)

    # Marker atom for the virtual trailing-newline edge of a terminal $/\Z.
    module TrailingNewlineAtom
      INSTANCE = Atom.new(source: "\n", options: {}, literal: true)
    end

    # Variant suppressed at a zero-consuming prefix anchor (e.g. /^$/ does not
    # swallow a leading newline in the whole-string language).
    class ZeroWidthNewlineAtom < Atom
    end
  end
end
