# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Regexp::Parser::FiniteLanguage do
  let(:alphabet) { %w[a b c] }

  def language(pattern, max_length = 4)
    described_class.new(pattern, alphabet, max_length)
  end

  it 'counts distinct strings from overlapping alternatives' do
    strings = language('a|ab|abc', 3).to_a

    expect(strings).to eq(%w[a ab abc])
    expect(language('a|ab|abc', 3).count).to eq(3)
  end

  it 'deduplicates strings with multiple parse paths' do
    strings = language('(ab|a)(b|bc)', 3).to_a

    expect(strings).to eq(%w[ab abb abc])
  end

  it 'uses shortlex ordering based on the supplied alphabet' do
    ordered_alphabet = %w[b a]
    finite = described_class.new('a|b|ba?', ordered_alphabet, 2)

    expect(finite.to_a).to eq(%w[b a ba])
  end

  it 'makes rank and unrank inverse for every accepted string' do
    patterns = [
      'a?b?c?',
      '(ab|a)(b|bc)',
      '[abc]{0,3}',
      'a{0,2}|a{1,3}',
      '(?i:ab)',
      '[a-c&&[^b]]',
      '\u{41 42}'
    ]

    patterns.each do |pattern|
      finite = described_class.new(pattern, %w[a b c A B C], 3)
      strings = finite.to_a

      strings.each_with_index do |string, rank|
        expect(finite.rank(string)).to eq(rank)
        expect(finite.unrank(rank)).to eq(string)
      end
    end
  end

  it 'exhaustively agrees with Ruby for a small alphabet' do
    patterns = [
      'a|bc?|[abc]',
      '(a?b)+',
      '[abc]*',
      'a{,2}|[bc]{2}',
      '(ab|c)(|a|b)',
      '(?:ab|a)(?:bc|c|b)'
    ]

    patterns.product((0..3).to_a).each do |pattern, max_length|
      finite = described_class.new(pattern, alphabet, max_length)
      matcher = Regexp.new("\\A(?:#{pattern})\\z")
      all_strings = (0..max_length).flat_map do |length|
        alphabet.repeated_permutation(length).map(&:join)
      end
      expected = all_strings.select { |string| matcher.match?(string) }

      expect(finite.to_a).to eq(expected)
      expect(finite.count).to eq(expected.length)
      expected.each do |string|
        expect(finite.unrank(finite.rank(string))).to eq(string)
      end
    end
  end

  it 'returns nil when ranking a string the expression does not match' do
    finite = language('ab', 3)

    expect(finite.rank('ac')).to be_nil
    expect(finite.rank('abc')).to be_nil
  end

  it 'rejects ranks outside the language' do
    finite = language('a|b', 1)

    expect { finite.unrank(2) }.to raise_error(ArgumentError, /out of range/)
    expect { finite.unrank(-1) }.to raise_error(ArgumentError)
  end

  it 'uses arbitrary precision integers' do
    finite = described_class.new('[ab]{200}', %w[a b], 200)

    expect(finite.count).to eq(1 << 200)
    expect(finite.rank('b' * 200)).to eq((1 << 200) - 1)
  end

  it 'samples with a supplied random source' do
    finite = described_class.new('a|b|ab', alphabet, 2)
    random = Random.new(7)
    samples = Array.new(20) { finite.sample(random) }

    accepted = finite.to_a
    expect(samples).to all(satisfy { |string| accepted.include?(string) })
  end

  it 'is reproducible with a fixed random seed' do
    build = -> do
      finite = described_class.new('[abc]{2}', alphabet, 2)
      10.times.map { finite.sample(Random.new(4242)) }
    end

    expect(build.call).to eq(build.call)
  end

  it 'supports keyword random sources' do
    finite = described_class.new('a', alphabet, 1)

    expect(finite.sample(random: Random.new(1))).to eq('a')
  end

  it 'rejects sampling without a random source' do
    expect { language('a', 1).sample }.to raise_error(ArgumentError)
  end

  it 'rejects unsupported expression features' do
    unsupported = {
      '(a)\1' => Regexp::Parser::FiniteLanguage::UnsupportedSyntaxError,
      '(a)\g<1>' => Regexp::Parser::FiniteLanguage::UnsupportedSyntaxError,
      '(?=a)' => Regexp::Parser::FiniteLanguage::UnsupportedSyntaxError,
      '(?!a)' => Regexp::Parser::FiniteLanguage::UnsupportedSyntaxError,
      '(?<=a)' => Regexp::Parser::FiniteLanguage::UnsupportedSyntaxError,
      '(?<!a)' => Regexp::Parser::FiniteLanguage::UnsupportedSyntaxError,
      '^a' => Regexp::Parser::FiniteLanguage::UnsupportedSyntaxError,
      '(?~a)' => Regexp::Parser::FiniteLanguage::UnsupportedSyntaxError,
      '\K' => Regexp::Parser::FiniteLanguage::UnsupportedSyntaxError
    }

    unsupported.each do |pattern, error_class|
      expect { described_class.new(pattern, alphabet, 2) }.to raise_error(error_class)
    end
  end

  it 'validates the alphabet and maximum length' do
    expect { described_class.new('a', ['ab'], 1) }
      .to raise_error(ArgumentError, /single-character/)
    expect { described_class.new('a', %w[a a], 1) }
      .to raise_error(ArgumentError, /duplicates/)
    expect { described_class.new('a', alphabet, -1) }
      .to raise_error(ArgumentError)
  end

  it 'exposes Parser convenience methods' do
    expect(Regexp::Parser.count('a|b|ab', alphabet, 2)).to eq(3)
    expect(Regexp::Parser.rank('a|b|ab', alphabet, 'ab')).to eq(2)
    expect(Regexp::Parser.unrank('a|b|ab', alphabet, 2, 1)).to eq('b')
    expect(Regexp::Parser.sample('a', alphabet, 1, Random.new(1))).to eq('a')
  end
end
