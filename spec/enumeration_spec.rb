# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Regexp::Parser::Enumeration do
  def enum_for(pattern, alphabet: %w[a b c], min_length: 0, max_length: 4)
    described_class.new(pattern, alphabet: alphabet, min_length: min_length, max_length: max_length)
  end

  # Reference implementation: all strings over the alphabet within the length
  # bounds that match as a whole, ordered by length, then by alphabet order.
  def brute_force(pattern, alphabet, min_length, max_length)
    re = /\A(?:#{pattern})\z/
    (min_length..max_length).flat_map do |len|
      alphabet.repeated_permutation(len).map(&:join).select { |string| re.match?(string) }
    end.sort_by { |string| [string.length, string.chars.map { |char| alphabet.index(char) }] }
  end

  # Exhaustively checks count, ordering, and rank/unrank inversion against
  # brute force for every string over the alphabet within the length bounds.
  RSpec::Matchers.define(:enumerate_like_brute_force) do |pattern, alphabet, min_length, max_length|
    match do |enum|
      @expected = brute_force(pattern, alphabet, min_length, max_length)
      next false unless enum.count == @expected.length

      strings = (0...enum.count).map { |index| enum.unrank(index) }
      next false unless strings == @expected

      @expected.each_with_index do |string, index|
        next false unless enum.rank(string) == index
        next false unless enum.unrank(enum.rank(string)) == string
      end

      non_members = (min_length..max_length).flat_map do |len|
        alphabet.repeated_permutation(len).map(&:join)
      end - @expected
      non_members.all? { |string| enum.rank(string).nil? && !enum.include?(string) }
    end

    failure_message do |enum|
      "expected #{pattern.inspect} to enumerate #{@expected.inspect}, " \
        "got count=#{enum.count}"
    end
  end

  describe 'exhaustive verification against brute force' do
    {
      'a'              => %w[a b],
      'ab'             => %w[a b],
      'a|b'            => %w[a b c],
      '(a|b)c'         => %w[a b c],
      'a*'             => %w[a b],
      'a+'             => %w[a b],
      'a?'             => %w[a b],
      'a{2,3}'         => %w[a b],
      'a{2,}'          => %w[a b],
      'a{2}'           => %w[a b],
      '(ab|a)*'        => %w[a b],
      '(a|aa)*'        => %w[a b],
      '(a|ab)(c|bcd)'  => %w[a b c],
      '(a|a)(a|a)'     => %w[a b],
      '(ab|a)b?'       => %w[a b],
      'a{0,2}b{0,2}'   => %w[a b],
      '(a(b|c)?)+'     => %w[a b c],
      '(x|y)(a|b)?'    => %w[a b c],
      '[ab]+'          => %w[a b c],
      '[^a]'           => %w[a b c],
      '[a-c&&b]'       => %w[a b c],
      '\d+'            => %w[a 1 2],
      '\w'             => %w[a _ -],
      '.'              => ['a', "\n"],
      '(?m:.)'         => ['a', "\n"],
      '\n'             => ['a', "\n"],
      '\x41'           => %w[A B],
      '(?i:a)b'        => %w[a A b],
      'a(?i)b'         => %w[a b B],
      '[[:alpha:]]'    => %w[a 1],
      '\p{alpha}'      => %w[a 1],
      '\Aa\z'          => %w[a b],
      '^a$'            => %w[a b],
      '(?# comment)a'  => %w[a b],
      '(a|b){1,2}c?'   => %w[a b c],
      '(ab){2,3}'      => %w[a b],
      'a*+'            => %w[a b],
      'a*?'            => %w[a b],
      ''               => %w[a b],
    }.each do |pattern, alphabet|
      it "enumerates #{pattern.inspect} over #{alphabet.inspect}" do
        expect(enum_for(pattern, alphabet: alphabet))
          .to enumerate_like_brute_force(pattern, alphabet, 0, 4)
      end
    end

    it 'respects min_length' do
      enum = enum_for('a*', alphabet: %w[a], min_length: 2, max_length: 3)
      expect(enum.count).to eq 2
      expect(enum.unrank(0)).to eq 'aa'
      expect(enum.unrank(1)).to eq 'aaa'
      expect(enum.rank('a')).to be_nil
    end
  end

  describe 'deduplication of overlapping parse paths' do
    it 'counts each distinct string only once' do
      expect(enum_for('(a|a)', max_length: 1).count).to eq 1
      expect(enum_for('a|a|a', max_length: 1).count).to eq 1
      # "ab" is matched by both alternatives
      expect(enum_for('(ab|a)b', max_length: 2).count).to eq 1
    end
  end

  describe 'arbitrary precision counts' do
    it 'counts beyond 64 bits exactly' do
      enum = enum_for('[ab]{64}', alphabet: %w[a b], min_length: 64, max_length: 64)
      expect(enum.count).to eq 2**64
      expect(enum.unrank(2**64 - 1)).to eq 'b' * 64
      expect(enum.rank('b' * 64)).to eq 2**64 - 1
      expect(enum.rank('a' * 64)).to eq 0
    end

    it 'handles very large counts' do
      enum = enum_for('[abc]{100}', min_length: 100, max_length: 100)
      expect(enum.count).to eq 3**100
    end
  end

  describe '#rank' do
    it 'returns nil for characters outside the alphabet' do
      expect(enum_for('a+', alphabet: %w[a], max_length: 2).rank('ab')).to be_nil
    end

    it 'returns nil for strings outside the length bounds' do
      enum = enum_for('a*', alphabet: %w[a], max_length: 2)
      expect(enum.rank('aaa')).to be_nil
    end

    it 'returns nil for unmatched strings' do
      expect(enum_for('a+', alphabet: %w[a b], max_length: 2).rank('b')).to be_nil
    end
  end

  describe '#unrank' do
    it 'raises IndexError for out-of-range indices' do
      enum = enum_for('a', max_length: 1)
      expect { enum.unrank(1) }.to raise_error(IndexError)
      expect { enum.unrank(-1) }.to raise_error(IndexError)
    end
  end

  describe '#sample' do
    let(:enum) { enum_for('(a|b){2}', alphabet: %w[a b], min_length: 2, max_length: 2) }

    it 'requires an explicit random source' do
      expect { enum.sample }.to raise_error(ArgumentError)
    end

    it 'reproduces the same sequence for the same random seed' do
      first  = Array.new(100) { enum.sample(random: Random.new(42)) }
      second = Array.new(100) { enum.sample(random: Random.new(42)) }
      expect(first).to eq second
    end

    it 'only returns members of the enumeration' do
      samples = Array.new(200) { enum.sample(random: Random.new(7)) }
      expect(samples).to all(satisfy { |string| enum.include?(string) })
    end

    it 'samples distinct strings uniformly' do
      counts = Hash.new(0)
      random = Random.new(1234)
      20_000.times { counts[enum.sample(random: random)] += 1 }
      expect(counts.keys).to match_array(%w[aa ab ba bb])
      counts.each_value do |amount|
        expect(amount).to be_within(500).of(5000)
      end
    end

    it 'raises when the language is empty' do
      empty = enum_for('z', alphabet: %w[a], max_length: 1)
      expect { empty.sample(random: Random.new(1)) }.to raise_error(Regexp::Parser::Error)
    end
  end

  describe 'constructor' do
    it 'accepts a Regexp with options' do
      enum = described_class.new(/ab/i, alphabet: %w[A B a b], min_length: 2, max_length: 2)
      expect(enum.count).to eq 4
      expect(enum.unrank(0)).to eq 'AB'
      expect(enum.unrank(3)).to eq 'ab'
    end

    it 'accepts a parsed Root expression' do
      root = Regexp::Parser.parse('a|b')
      expect(described_class.new(root, alphabet: %w[a b], max_length: 1).count).to eq 2
    end

    it 'accepts a String alphabet' do
      expect(described_class.new('a|b', alphabet: 'ab', max_length: 1).count).to eq 2
    end

    it 'rejects an empty alphabet' do
      expect { described_class.new('a', alphabet: [], max_length: 1) }
        .to raise_error(ArgumentError, /empty/)
    end

    it 'rejects duplicate alphabet characters' do
      expect { described_class.new('a', alphabet: %w[a a], max_length: 1) }
        .to raise_error(ArgumentError, /duplicate/)
    end

    it 'rejects multi-character alphabet entries' do
      expect { described_class.new('a', alphabet: ['ab'], max_length: 1) }
        .to raise_error(ArgumentError, /single-character/)
    end

    it 'rejects max_length < min_length' do
      expect { described_class.new('a', alphabet: %w[a], min_length: 2, max_length: 1) }
        .to raise_error(ArgumentError, /min_length/)
    end
  end

  describe 'unsupported expressions' do
    {
      '(a)\1'              => /backreferences/,
      '(?<x>a)\k<x>'       => /backreferences/,
      '(?<x>a|\g<x>)'      => /backreferences/,
      '(?=a)'              => /lookaround/,
      '(?!a)'              => /lookaround/,
      '(?<=a)'             => /lookaround/,
      '(?<!a)'             => /lookaround/,
      '(a)?(?(1)b|c)'      => /conditional/,
      '(?>a)'              => /atomic/,
      '(?~a)'              => /absence/,
      '\Ka'                => /\K/,
      'a\b'                => /anchor/,
      '\Ga'                => /anchor/,
      'a\Z'                => /anchor/,
      '\R'                 => /variable-length/,
      '\X'                 => /variable-length/,
      '\u{61 62}'          => /variable-length/,
    }.each do |pattern, message|
      it "rejects #{pattern.inspect}" do
        expect { enum_for(pattern, alphabet: %w[a b c], max_length: 2) }
          .to raise_error(Regexp::Parser::Enumeration::UnsupportedExpressionError, message)
      end
    end
  end
end
