# frozen_string_literal: true

require 'spec_helper'

RSpec.describe('Optimizer') do
  # Exhaustive equivalence over a tiny alphabet. We compare much more than
  # match/no-match: the full MatchData snapshot (match range plus every
  # numbered and named capture range) is compared.
  ALPHABET = %w[a b c].freeze

  def all_strings(max_length)
    strings = ['']
    (1..max_length).each do |length|
      ALPHABET.repeated_permutation(length).each { |chars| strings << chars.join }
    end
    strings
  end

  def snapshot(regexp, string)
    match = regexp.match(string)
    return nil unless match

    captures = (1..match.size - 1).map { |index| match.offset(index) }
    named = {}
    match.names.each { |name| named[name] = match.offset(name) rescue nil }
    { match: match.offset(0), captures: captures, named: named }
  end

  def options_flags(options)
    options.is_a?(Integer) ? [options] : []
  end

  def assert_exhaustively_equivalent(pattern, max_length = 4, options = nil)
    result = Regexp::Parser::Optimizer.optimize(pattern, options: options)
    original = Regexp.new(result.original, *options_flags(options))
    optimized = Regexp.new(result.optimized, *options_flags(options))

    all_strings(max_length).each do |string|
      before = snapshot(original, string)
      after  = snapshot(optimized, string)
      next if before == after
      raise "divergence on #{string.inspect}: #{pattern.inspect} " \
            "(#{result.optimized.inspect}) #{before.inspect} != #{after.inspect}"
    end
    result
  end

  # Patterns the analyzer is allowed to rewrite. Every change is proven
  # equivalent by the exhaustive run.
  REWRITABLE_PATTERNS = [
    'a*b', 'a+b', 'b+a', 'a*', 'c+',
    '[ab]+c', '(?:ab)+c',
    '(?:a|b)+c', '(a)(b+)',
    '(?:a+)(?:b+)', '(a|b)*c', '(a|b)*', '(?<x>a+)b', '(?<x>a+)(?<y>b+)',
    'a*b*c+', '(?:a)(?:b)', '(?:a|b)c', 'xa*y', 'a*[bc]',
    '(?:[ab]+)c', 'a*b|(?:a|b)c', '(a*)(b+)', '(a*)(a+)'
  ].freeze

  REWRITABLE_PATTERNS.each do |pattern|
    specify("rewrite is equivalent: #{pattern.inspect}") do
      result = assert_exhaustively_equivalent(pattern)
      expect(result.changed?).to be(true)
    end
  end

  specify('case-insensitive expansion is equivalent') do
    result = assert_exhaustively_equivalent('a*b', 4, Regexp::IGNORECASE)
    expect(result.optimized).to include('*+')
  end

  # Patterns containing constructs the analyzer must refuse. They are
  # returned exactly unchanged and still pass the exhaustive check.
  KEPT_PATTERNS = [
    '[ab]+b', '[a-c]+c', '[abc]{2,5}b', '(?:ab)*ab', '(?:a|b)*b',
    '(?:ab|ac)+ab', 'aa*a', 'ab?b', '(?:ab|ba)ab', 'a{2,4}b', 'a{2,}c', 'a{2}b',
    '(?:a|ab)c',      # same-position alternative switch
    '(?:ab|ax)xc',    # overlapping alternatives
    '(?:a|a)c',       # identical alternatives
    '(a|ab)c',        # capturing version
    '(a*)[ab]',       # overlap through a set; greedy capture changes
    '(\d*)(\d+)',     # greedy capture split depends on backtracking
    '(?=a)a*',        # adjacent lookahead
    '(a)\1',          # backreference
    '\w+b',           # unbounded character type
    '[^a]+b',         # negated set
    '[\w]+b',         # set containing a character type
    'a++b',           # already possessive
    'a*?b',            # reluctant
    '(?~a)b',         # absence group
    '\Kab',           # keep marker
    '(?>ab)ab',       # already atomic
    '(a|b)*?c',       # reluctant outer
    '\d+a',           # character type
  ].freeze

  KEPT_PATTERNS.each do |pattern|
    specify("kept unchanged: #{pattern.inspect}") do
      result = Regexp::Parser::Optimizer.optimize(pattern)
      expect(result.optimized).to eql(pattern)
      assert_exhaustively_equivalent(pattern)
    end
  end

  specify('recursive subexpression calls leave the whole pattern unchanged') do
    pattern = '(?<x>a+)\g<x>b'
    result = Regexp::Parser::Optimizer.optimize(pattern)
    expect(result.optimized).to eql(pattern)
    expect(result.changes).to be_empty
    expect(result.skipped.map(&:kind)).to eql([:recursion])
  end

  specify('numbered recursion is left unchanged') do
    pattern = '(a)\g<1>b'
    result = Regexp::Parser::Optimizer.optimize(pattern)
    expect(result.optimized).to eql(pattern)
  end

  # Known counterexamples: these rewrites WOULD change greedy capture or the
  # match, which is exactly why the analyzer must not perform them.
  describe('counterexamples (must never be rewritten)') do
    COUNTEREXAMPLES = [
      ['(a*)(a+)', '(a*+)(a+)', 'aaa', [0, 3], nil],
      ['(a*)[ab]', '(a*+)[ab]', 'aaa', [0, 3], nil],
      ['(a|ab)c', '(?>a|ab)c', 'abc', [0, 3], nil],
      ['(?:a|ab)c', '(?>a|ab)c', 'abc', [0, 3], nil],
      ['(?:y*y)y', '(?>y*y)y', 'yy', [0, 2], nil],
      # greedy capture split changes, and the whole pattern stays untouched
      ['(\d*)(\d+)', '(\d*+)(\d+)', '123', [0, 3], nil],
      # adjacent lookahead that overlaps the quantifier body
      ['a+(?=a)a', 'a++(?=a)a', 'aaa', [0, 3], nil],
      # absence group lets backtracking escape into the preceding quantifier
      ['ab+(?~c)b', 'ab++(?~c)b', 'abbb', [0, 4], nil],
    ].freeze

    COUNTEREXAMPLES.each do |safe, unsafe, string, safe_match, unsafe_match|
      specify("#{safe.inspect} must not become #{unsafe.inspect}") do
        safe_data = Regexp.new(safe).match(string)&.offset(0)
        unsafe_data = Regexp.new(unsafe).match(string)&.offset(0)
        expect(safe_data).to eql(safe_match)
        expect(unsafe_data).to eql(unsafe_match)

        result = Regexp::Parser::Optimizer.optimize(safe)
        expect(result.optimized).not_to include(unsafe[1..-2])
      end
    end
  end

  specify('only the independent second capture is possessivized in (a*)(a+)') do
    result = Regexp::Parser::Optimizer.optimize('(a*)(a+)')
    expect(result.optimized).to eql('(a*)(a++)')
    expect(result.changes.map(&:location)).to eql([5])
  end

  specify('reports each change with location and proof') do
    result = Regexp::Parser::Optimizer.optimize('a*b|(?:a|b)c')
    expect(result.changes.length).to eql(2)
    possessive = result.changes.find { |change| change.kind == :possessive }
    atomic = result.changes.find { |change| change.kind == :atomic }
    expect(possessive.location).to be_a(Integer)
    expect(possessive.source).to eql('a*')
    expect(possessive.target).to eql('a*+')
    expect(possessive.proof).to match(/disjoint/i)
    expect(atomic.source).to eql('(?:a|b)')
    expect(atomic.target).to eql('(?>a|b)')
    expect(atomic.proof).to match(/backtrack/i)
  end

  specify('accepts a Regexp and preserves its options') do
    result = Regexp::Parser::Optimizer.optimize(/a*b/i)
    expect(result.original).to eql('a*b')
    expect(result.optimized).to eql('a*+b')
    expect(result.to_regexp).to eql(/a*+b/i)
    expect(result.original_regexp).to eql(/a*b/i)
  end

  specify('accepts a pattern String with options') do
    result = Regexp::Parser::Optimizer.optimize('a*b', options: Regexp::IGNORECASE)
    expect(result.to_regexp).to eql(/a*+b/i)
  end

  specify('skipped sites carry a reason') do
    result = Regexp::Parser::Optimizer.optimize('\w+b')
    expect(result.changes).to be_empty
    expect(result.skipped.first.reason).to match(/unsupported/i)
  end
end
