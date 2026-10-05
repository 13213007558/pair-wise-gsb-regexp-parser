# frozen_string_literal: true

require 'spec_helper'

BML = Regexp::BoundedMatchLength

RSpec.describe(Regexp::BoundedMatchLength) do
  def exhaustive_combinations(pattern, alphabet, max_length, groups = nil)
    anchored = Regexp.new("\\A(?:#{pattern.source})\\z")
    expected = {}

    (0..max_length).each do |length|
      alphabet.repeated_permutation(length).each do |chars|
        match = anchored.match(chars.join)
        next unless match

        values = Array(groups).map do |group|
          value =
            if group.is_a?(Symbol)
              match.named_captures.fetch(group.to_s)
            else
              match.captures.fetch(group - 1)
            end
          value && value.length
        end
        (expected[length] ||= []) << values
      end
    end

    expected.transform_values { |values| values.uniq.sort }.sort
  end

  describe '::of' do
    it 'accepts Regexps, Strings, and expressions' do
      expect(BML.of(/a/).lengths).to eq([1])
      expect(BML.of('a').lengths).to eq([1])
      expect(BML.of(RP.parse('a')).lengths).to eq([1])
    end

    it 'keeps total length and capture lengths correlated through backreferences' do
      analysis = BML.of(/(a{1,3})\1/)

      expect(analysis.lengths).to eq([2, 4, 6])
      expect(analysis.minmax).to eq([2, 6])
      expect(analysis.combinations).to eq([[2, [1]], [4, [2]], [6, [3]]])
    end

    it 'uses the last result of a repeated capture in a later backreference' do
      analysis = BML.of(/(a|bb){2}\1/)

      expect(analysis.lengths).to eq([3, 4, 5, 6])
      expect(analysis.combinations).to eq(
        [[3, [1]], [4, [1]], [5, [2]], [6, [2]]]
      )
    end

    it 'correlates repeated backreferences' do
      analysis = BML.of(/(a|bb)\1{0,2}/)

      expect(analysis.lengths).to eq([1, 2, 3, 4, 6])
      expect(analysis.combinations).to eq(
        [
          [1, [1]],
          [2, [1]], [2, [2]],
          [3, [1]],
          [4, [2]],
          [6, [2]]
        ]
      )
    end

    it 'keeps two references to the same capture correlated' do
      analysis = BML.of(/(?<x>a|bb)\k<x>\k<x>/, groups: :x)

      expect(analysis.lengths).to eq([3, 6])
      expect(analysis.combinations).to eq([[3, [1]], [6, [2]]])
    end

    it 'distinguishes numbered capture groups that did not participate' do
      analysis = BML.of(/(?:(a)(b)?){2}/)

      expect(analysis.lengths).to eq([2, 3, 4])
      expect(analysis.combinations).to eq(
        [
          [2, [1, nil]],
          [3, [1, 1]],
          [4, [1, 1]]
        ]
      )
    end

    it 'resolves named references, including duplicate named captures' do
      analysis = BML.of(/(?:(?<x>a)|(?<x>bb))\k<x>/, groups: :x)

      expect(analysis.lengths).to eq([2, 4])
      expect(analysis.combinations).to eq([[2, [1]], [4, [2]]])
      expect(BML.of(/(?:(?<x>a)|(?<x>bb))\k<x>/).combinations).to eq(
        [[2, [1, nil]], [4, [nil, 2]]]
      )
    end

    it 'accepts a mix of numbered and named group selectors' do
      analysis = BML.of(/(?<a>a|bb)(?<b>c|d)\k<a>\k<b>/,
                         groups: [1, :b, :a])

      expect(analysis.combinations).to eq(
        [[4, [1, 1, 1]], [6, [2, 1, 2]]]
      )
    end

    it 'matches Ruby exhaustively for the correlated examples' do
      examples = [
        [/(a{1,3})\1/, %w[a b], 6, [1]],
        [/(a|bb){2}\1/, %w[a b], 6, [1]],
        [/(a|bb)\1{0,2}/, %w[a b], 6, [1]],
        [/(?:(a)(b)?){2}/, %w[a b], 4, [1, 2]],
        [/(a|)(b)?/, %w[a b], 2, [1, 2]],
        [/(a{0,2})(b?)\1\2/, %w[a b], 6, [1, 2]],
        [/(?<x>a)(?<x>b)?\k<x>/, %w[a b], 3, :x],
        [/(?<a>a|bb)(?<x>c|d)\k<a>\k<x>/, %w[a b c d], 6, :x],
        [/(?<x>(a|bb)(c)?){2}\k<x>/, %w[a b c], 9, :x]
      ]

      examples.each do |pattern, alphabet, max_length, groups|
        predicted = BML.of(pattern, groups: groups, state_limit: 100_000)
                     .combinations
                     .group_by(&:first)
                     .transform_values { |rows| rows.map(&:last).uniq.sort }
                     .sort
        actual = exhaustive_combinations(pattern, alphabet, max_length, groups)

        expect(predicted).to eq(actual)
      end
    end
  end

  describe 'unsupported input' do
    it 'rejects unbounded quantifiers instead of pretending infinity is exact' do
      expect { BML.of(/a*/) }.to raise_error(
        BML::UnsupportedExpressionError, /unbounded quantifiers/
      )
    end

    it 'rejects assertions' do
      expect { BML.of(/(?=a)/) }.to raise_error(
        BML::UnsupportedExpressionError, /not supported/
      )
    end

    it 'rejects subexpression calls' do
      expect { BML.of(/(a)\g<1>/) }.to raise_error(
        BML::UnsupportedExpressionError, /subexpression calls/
      )
    end

    it 'rejects variable-length line breaks and grapheme clusters' do
      expect { BML.of(/\R/) }.to raise_error(BML::UnsupportedExpressionError)
      expect { BML.of(/\X/) }.to raise_error(BML::UnsupportedExpressionError)
    end

    it 'rejects unknown selected group names' do
      expect { BML.of(/a/, groups: :x) }.to raise_error(
        BML::UnsupportedExpressionError, /unknown named capture/)
    end

    it 'rejects unknown selected group numbers' do
      expect { BML.of(/(a)/, groups: 2) }.to raise_error(
        BML::UnsupportedExpressionError, /unknown capture group 2/)
    end
  end

  describe 'state limits' do
    it 'raises with the reached and configured state counts' do
      expect do
        BML.of(/(?:a|bb|ccc|dddd){0,3}/, state_limit: 10)
      end.to raise_error(BML::StateLimitError) do |error|
        expect(error.state_count).to be > 10
        expect(error.state_limit).to eq(10)
        expect(error.message).to include('exceeded 10 states')
      end
    end
  end

  describe '#inspect' do
    it 'reports the exact lengths and configured bound' do
      analysis = BML.of(/a{1,2}/, state_limit: 42)

      expect(analysis.inspect).to include('lengths=[1, 2]')
      expect(analysis.inspect).to include('state_count=2')
      expect(analysis.inspect).to include('state_limit=42')
    end
  end

  describe 'Expression::Base#bounded_match_length' do
    it('returns the analysis') do
      expect(RP.parse(/(a?)\1/).bounded_match_length.lengths).to eq([0, 2])
    end
  end
end
