# frozen_string_literal: true

require 'spec_helper'
require 'regexp_parser'

RSpec.describe Regexp::Parser::FiniteLanguage do
  FL = described_class

  # Exact whole-string membership using Ruby itself. Unanchored patterns are
  # wrapped so the match must cover the entire string.
  def ruby_members(pattern, alphabet, n)
    anchor_tokens = ['\A', '\G', '\z', '\Z', '^', '$']
    anchored = anchor_tokens.any? { |token| pattern.include?(token) }
    re =
      if anchored
        Regexp.new(pattern)
      else
        Regexp.new('\A(?:' + pattern + ')\z')
      end
    alphabet.repeated_permutation(n).map(&:join).select do |s|
      m = re.match(s)
      if anchored
        m && m.begin(0).zero? &&
          (m.end(0) == s.length ||
            (m.end(0) == s.length - 1 && s.end_with?("\n") &&
             (pattern.end_with?('$') || pattern.end_with?('\Z'))))
      else
        m
      end
    end.sort
  end

  ABCN = %w[a b c \n].freeze

  shared_examples 'exact enumeration' do |pattern, alphabet|
    (0..3).each do |n|
      it "counts, ranks and enumerates #{pattern.inspect} at n=#{n}" do
        lang = FL.new(pattern, alphabet)
        expected = ruby_members(pattern, alphabet, n)
        expect(lang.count(n).value).to eq(expected.size)
        if expected.any?
          ranked = expected.size.times.map { |i| lang.nth(n, i).value }
          expect(ranked).to eq(expected)
          expect(lang.each(n).to_a).to eq(expected)
        end
      end
    end
  end

  include_examples 'exact enumeration', 'a', %w[a b]
  include_examples 'exact enumeration', 'a|a', %w[a b]
  include_examples 'exact enumeration', 'a|aa', %w[a b]
  include_examples 'exact enumeration', '(a|aa)(a|)', %w[a b]
  include_examples 'exact enumeration', '[ab]', %w[a b c]
  include_examples 'exact enumeration', '[^a]', %w[a b c 0]
  include_examples 'exact enumeration', 'a?', %w[a b]
  include_examples 'exact enumeration', 'a*', %w[a b]
  include_examples 'exact enumeration', 'a+', %w[a b]
  include_examples 'exact enumeration', 'a{2}', %w[a b]
  include_examples 'exact enumeration', 'a{1,2}', %w[a b]
  include_examples 'exact enumeration', '(a|b)(a|b)', %w[a b]
  include_examples 'exact enumeration', '\d+', %w[a 0 1]
  include_examples 'exact enumeration', '\w?', %w[a 0 _ -]
  include_examples 'exact enumeration', '\s', ['a', ' ', "\n"]
  include_examples 'exact enumeration', 'a.c', ['a', 'b', 'c', "\n"]
  include_examples 'exact enumeration', '(?i:a)', %w[a A b]
  include_examples 'exact enumeration', '\Aabc\z', %w[a b c]
  include_examples 'exact enumeration', '^a$', ['a', 'b', "\n"]
  include_examples 'exact enumeration', 'a$', ['a', 'b', "\n"]
  include_examples 'exact enumeration', 'a\Z', ['a', 'b', "\n"]
  include_examples 'exact enumeration', '^$', %w[a b]

  it 'counts with arbitrary-precision integers' do
    lang = FL.new('.*', %w[a b])
    count = lang.count(64).value
    expect(count).to eq(2**64)
    expect(count).to be_an(Integer)
  end

  it 'supports a String, Range and Array alphabet' do
    expect(FL.new('a', 'ab').alphabet).to eq(%w[a b])
    expect(FL.new('a', 'a'..'c').alphabet).to eq(%w[a b c])
    expect(FL.new('a', ['x']).alphabet).to eq(['x'])
  end

  it 'dedupes overlapping branches so a|a is counted once' do
    lang = FL.new('a|a', %w[a b])
    expect(lang.count(1).value).to eq(1)
  end

  it 'handles the empty string language explicitly' do
    lang = FL.new('a?', %w[a b])
    expect(lang.count(0).value).to eq(1)
    expect(lang.nth(0, 0).value).to eq('')
    expect(lang.each(0).to_a).to eq([''])
  end

  it 'rejects out-of-range ranks but never fakes a value' do
    lang = FL.new('a', %w[a])
    expect { lang.nth(1, 1).value! }.to \
      raise_error(FL::InvalidQuery)
    expect { lang.nth(1, -1).value! }.to \
      raise_error(FL::InvalidQuery)
  end

  it 'samples uniformly with a fixed Integer/Random seed and reproduces' do
    lang = FL.new('[abc]', %w[a b c])
    random = Random.new(7)
    s1 = 2000.times.map { lang.sample(1, seed: random).value }
    random2 = Random.new(7)
    s2 = 2000.times.map { lang.sample(1, seed: random2).value }
    expect(s1).to eq(s2)
    expect(s1.uniq.sort).to eq(%w[a b c])
    counts = s1.tally
    # Every character should get a fair share (well within tolerance).
    counts.each_value { |c| expect(c).to be_between(550, 800) }
  end

  it 'never biases toward overlapping paths when sampling' do
    # Two overlapping branches produce the same strings; frequencies must
    # match the single-branch language, not be doubled for shared results.
    alphabet = %w[a b c]
    single = FL.new('a?[bc]', alphabet)
    overlap = FL.new('a?[bc]|a?[bc]', alphabet)
    sample_counts = ->(lang) {
      10_000.times.with_object(Hash.new(0)) do |i, h|
        h[lang.sample(2, seed: 100 + i).value] += 1
      end
    }
    a = sample_counts.call(single)
    b = sample_counts.call(overlap)
    expect(b.keys.sort).to eq(a.keys.sort)
    a.each_key { |k| expect(b[k].to_f / 10_000).to be_within(0.02).of(a[k].to_f / 10_000) }
  end

  it 'returns an incomplete Result when the budget is exhausted' do
    lang = FL.new('.*', %w[a b])
    result = lang.count(100, budget: 1)
    expect(result).not_to be_complete
    expect(result.reason).to match(/budget/i)
    expect { result.value! }.to raise_error(FL::BudgetExhausted)
  end

  it 'completes within a generous budget' do
    lang = FL.new('.*', %w[a b])
    expect(lang.count(8, budget: 50_000)).to be_complete
  end

  it 'rejects backreferences and recursion' do
    expect { FL.new('(a)\1', %w[a]) }.to raise_error(FL::UnsupportedFeature)
    # An unresolved recursion call is rejected by the parser itself.
    expect { FL.new('\g<1>', %w[a]) }.to raise_error(Regexp::Parser::Error)
  end

  it 'rejects lookarounds, word boundaries and keep marks' do
    ['a(?=b)', 'a(?!b)', '(?<=a)b', '\ba', 'a\K'].each do |pattern|
      expect { FL.new(pattern, %w[a b]) }.to raise_error(FL::UnsupportedFeature)
    end
  end

  it 'rejects possessive quantifiers (not a regular language)' do
    expect { FL.new('a*+', %w[a]) }.to raise_error(FL::UnsupportedFeature)
    expect { FL.new('a++', %w[a]) }.to raise_error(FL::UnsupportedFeature)
  end

  it 'rejects multiline ^/$' do
    expect { FL.new(Regexp.new('^a$', Regexp::MULTILINE), %w[a]) }.to \
      raise_error(FL::UnsupportedFeature)
  end

  it 'accepts a Regexp and a String pattern' do
    expect { FL.new(/a[bc]/, %w[a b c]) }.not_to raise_error
    expect(FL.new('a[bc]', %w[a b c]).count(2).value).to eq(2)
  end
end
