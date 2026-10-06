# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Regexp::Parser::Language do
  Language = Regexp::Parser::Language
  UnsupportedFeatureError = Regexp::Parser::UnsupportedFeatureError
  InfiniteAlphabetError = Regexp::Parser::InfiniteAlphabetError
  LanguageArgumentError = Regexp::Parser::LanguageArgumentError

  def brute(pattern, alphabet, max_length, options = 0)
    reference = Regexp.new('\A(?:' + pattern + ')\z', options)
    (0..max_length).map do |length|
      words = (0...alphabet.length ** length).map do |index|
        word = ''.dup
        value = index
        length.times do
          word << alphabet[value % alphabet.length]
          value /= alphabet.length
        end
        word
      end
      words.select { |word| reference.match?(word) }.sort
    end
  end

  it 'counts distinct strings, not syntactic paths' do
    language = Language.new(/a|a/)

    expect(language.count(1).value).to eq(1)
    expect(language.enumerate(1).value).to eq(['a'])
  end

  it 'counts the empty string at length zero' do
    expect(Language.new(//).count(0).value).to eq(1)
    expect(Language.new(/a?/).count(0).value).to eq(1)
    expect(Language.new(/(?:|a)/).count(0).value).to eq(1)
    expect(Language.new(/a/).count(0).value).to eq(0)
  end

  it 'uses big integers for counts' do
    count = Language.new(/[abcdefghij]*/).count(40).value

    expect(count).to eq(10 ** 40)
    expect(count).to be_a(Integer)
    expect(count > 2 ** 64).to eq(true)
  end

  it 'supports all finite quantifier forms' do
    language = Language.new(/(?:ab){2,3}/)

    expect(language.count(3).value).to eq(0)
    expect(language.count(4).value).to eq(1)
    expect(language.count(6).value).to eq(1)
    expect(language.enumerate(6).value).to eq(['ababab'])
  end

  it 'respects explicit finite alphabets for open character classes' do
    language = Language.new(/./, alphabet: 'abc')

    expect(language.count(1).value).to eq(3)
    expect(language.enumerate(1).value).to eq(%w[a b c])
  end

  it 'requires an alphabet for unbounded classes' do
    expect { Language.new(/[^a]/).alphabet }.to raise_error(InfiniteAlphabetError)
    expect { Language.new(/\p{Alpha}/).alphabet }.to raise_error(InfiniteAlphabetError)
  end

  it 'rejects backreferences, recursion and unsupported assertions' do
    expect { Language.new(/(a)\1/) }.to raise_error(UnsupportedFeatureError)
    expect { Language.new(/(?<x>a)\k<x>/) }.to raise_error(UnsupportedFeatureError)
    expect { Language.new(/(?=a)b/) }.to raise_error(UnsupportedFeatureError)
    expect { Language.new(/(?!a)b/) }.to raise_error(UnsupportedFeatureError)
    expect { Language.new(/(?<=a)b/) }.to raise_error(UnsupportedFeatureError)
    expect { Language.new(/(?~a)b/) }.to raise_error(UnsupportedFeatureError)
    expect { Language.new(/a\Kb/) }.to raise_error(UnsupportedFeatureError)
  end

  it 'supports beginning and end anchors' do
    language = Language.new(/\Aab*\z/)

    expect((0..4).map { |n| language.count(n).value }).to eq([0, 1, 1, 1, 1])
    expect(language.enumerate(3).value).to eq(['abb'])
  end

  it 'supports word boundaries' do
    language = Language.new(/\bword\b/)

    expect(language.count(3).value).to eq(0)
    expect(language.count(4).value).to eq(1)
    expect(language.enumerate(4).value).to eq(['word'])
  end

  it 'returns incomplete results instead of biased partial counts' do
    language = Language.new(/(?:ab|cd){12}/, budget: 0)
    result = language.count(5)

    expect(result).to be_incomplete
    expect(result.budget.exhausted?).to eq(true)
  end

  it 'reports when a small budget is still sufficient' do
    result = Language.new(/a{5}/).count(5, budget: 10_000)

    expect(result).to be_complete
    expect(result.value).to eq(1)
  end

  it 'raises when nth rank is out of range' do
    language = Language.new(/a/)

    expect { language.nth(1, 1) }.to raise_error(
      LanguageArgumentError, /rank 1 is out of range/,
    )
  end

  it 'makes small enumeration, total count and every rank consistent' do
    patterns = [
      'a|a', 'a?', '(a)?b*', '[ab]{0,3}', 'a+|aa|aaa',
      '(?:ab|a)(?:b|ab)', 'b*a*b*', '(?:|a)(?:|b)',
      '\d[0-2]?', 'a|\w', '\Aab*\z', '\bword\b',
    ]
    alphabet = 'ab0_'.chars.sort.join

    patterns.each do |pattern|
      expected = brute(pattern, alphabet, 5)
      language = Language.new(Regexp.new(pattern), alphabet: alphabet)

      expected.each_with_index do |words, length|
        expect(language.count(length).value).to eq(words.length)
        expect(language.enumerate(length).value).to eq(words)
        words.each_with_index do |word, rank|
          expect(language.nth(length, rank).value).to eq(word)
        end
      end
    end
  end

  it 'reproduces samples for a fixed seed and draws every distinct string' do
    language = Language.new(/[ab]{2}/)
    first = language.samples(2, 500, seed: 42).value
    second = language.samples(2, 500, seed: 42).value

    expect(second).to eq(first)
    expect(first.uniq.sort).to eq(%w[aa ab ba bb])
  end

  it 'accepts string seeds' do
    language = Language.new(/[ab]/)

    expect(language.sample(1, seed: 'seed').value).to eq(
      language.sample(1, seed: 'seed').value,
    )
  end

  it 'does not bias overlapping branches' do
    # Every length 1..4 has exactly one language word even though the
    # syntax provides several paths to it.
    language = Language.new(/a+|aa|aaa|aaaa/)

    (1..4).each do |length|
      expect(language.count(length).value).to eq(1)
      expect(language.enumerate(length).value).to eq(['a' * length])
    end

    samples = Array.new(50) { language.sample(3, seed: 7).value }
    expect(samples.uniq).to eq(['aaa'])
  end

  it 'samples uniformly from an overlapping-branch language' do
    language = Language.new(/a|aa|aaa/)
    words = Array.new(2_000) { language.sample(2, seed: 99).value }.compact

    expect(words.uniq).to eq(['aa'])
  end

  it 'can be built from a parse tree or source string' do
    tree = Regexp::Parser.parse(/[ab]/)

    expect(Language.new(tree).enumerate(1).value).to eq(%w[a b])
    expect(Language.new('[ab]').enumerate(1).value).to eq(%w[a b])
  end

  it 'rejects invalid lengths and ranks' do
    language = Language.new(/a/)

    expect { language.count(-1) }.to raise_error(LanguageArgumentError)
    expect { language.nth(1, -1) }.to raise_error(LanguageArgumentError)
  end
end
