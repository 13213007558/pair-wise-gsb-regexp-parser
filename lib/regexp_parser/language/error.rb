# frozen_string_literal: true

class Regexp
  class Parser
    # Base class for errors raised by the finite-language facilities.
    class LanguageError < ::StandardError; end

    # Raised when a regexp uses a feature that cannot be translated into a
    # finite formal language, such as backreferences, recursion, lookarounds
    # or unbounded character classes (e.g. +[^x]+ or +.+) without an
    # explicit alphabet.
    class UnsupportedFeatureError < LanguageError; end

    # Raised when an explicit alphabet is required to make the language
    # finite, e.g. for +\\p{Alpha}+ or a negated character set.
    class InfiniteAlphabetError < LanguageError; end

    # Raised for arguments that cannot be used to build a finite language.
    class LanguageArgumentError < LanguageError; end
  end
end
