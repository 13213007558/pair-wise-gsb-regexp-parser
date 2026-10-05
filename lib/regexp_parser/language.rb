# frozen_string_literal: true

require 'set'
require_relative 'language/result'
require_relative 'language/nfa'
require_relative 'language/dfa'
require_relative 'language/compiler'
require_relative 'language/comparator'

class Regexp::Parser
  module Language
    def self.equivalent(left, right, alphabet, **options)
      Comparator.equivalent(left, right, alphabet, **options)
    end

    def self.subset(left, right, alphabet, **options)
      Comparator.subset(left, right, alphabet, **options)
    end
  end
end
