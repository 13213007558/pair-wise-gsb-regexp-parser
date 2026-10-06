# frozen_string_literal: true

require 'spec_helper'

RSpec.describe('Optimizer fuzz') do
  # Generates random patterns built only from constructs the optimizer can
  # reason about, then exhaustively verifies equivalence on a tiny alphabet.
  FUZZ_ALPHABET = %w[a b].freeze
  ATOMS = %w[a b c ab bc a].freeze
  QUANTIFIERS = ['', '*', '+', '?', '{2,3}', '*?', '+?', '*+', '++'].freeze
  WRAPPERS = ['(?:%s)', '(%s)', '(?>(%s))'].freeze
  SUFFIXES = ['', 'a', 'b', 'c'].freeze

  def build_pattern(depth)
    parts = Array.new(rand(1..3)) do
      atom = ATOMS[rand(ATOMS.length)] + QUANTIFIERS[rand(QUANTIFIERS.length)]
      if depth > 0 && rand(3).zero?
        inner = build_pattern(depth - 1)
        wrapper = WRAPPERS[rand(WRAPPERS.length)]
        wrapper.include?('%s') ? format(wrapper, inner) : inner
      else
        atom
      end
    end
    if parts.length > 1 && rand(2).zero?
      parts.join('|')
    else
      parts.join
    end
  end

  def all_strings(max_length)
    strings = ['']
    (1..max_length).each do |length|
      FUZZ_ALPHABET.repeated_permutation(length).each { |chars| strings << chars.join }
    end
    strings
  end

  def snapshot(regexp, string)
    match = regexp.match(string)
    return nil unless match
    captures = (1..match.size - 1).map { |index| match.offset(index) }
    named = {}
    match.names.each { |name| named[name] = match.offset(name) rescue nil }
    [match.offset(0), captures, named]
  end

  300.times do |index|
    specify("random pattern #{index} is equivalent after optimization") do
      srand(909_090 + index)
      4.times do
        pattern = begin
          candidate = build_pattern(2) + SUFFIXES[rand(SUFFIXES.length)]
          Regexp.new(candidate)
          candidate
        rescue RegexpError
          next
        end

        result = Regexp::Parser::Optimizer.optimize(pattern)
        original = Regexp.new(result.original)
        optimized = Regexp.new(result.optimized)

        all_strings(4).each do |string|
          expect(snapshot(optimized, string)).to eql(snapshot(original, string)),
            "#{pattern.inspect} -> #{result.optimized.inspect} diverged on #{string.inspect}"
        end
      end
    end
  end
end
