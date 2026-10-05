# frozen_string_literal: true

require 'spec_helper'

LA = Regexp::LengthAnalysis

RSpec.describe(Regexp::LengthAnalysis) do
  # Exhaustively matches the pattern against all strings over the alphabet
  # up to max_length and compares the resulting [total, *group_lengths]
  # tuples with the analysis, group by group.
  def expect_exhaustive_match(source, alphabet:, max_length:)
    analysis = LA.of(source)
    regexp = Regexp.new("\\A(?:#{source})\\z")
    actual = []
    (0..max_length).each do |length|
      alphabet.repeated_permutation(length) do |chars|
        string = chars.join
        next unless (match = regexp.match(string))

        actual << [length, *match.captures.map { |cap| cap && cap.length }]
      end
    end
    expect(analysis.tuples).to match_array(actual.uniq)
  end

  specify('literal') { expect(LA.of('abc').tuples).to eq [[3]] }
  specify('dot') { expect(LA.of('.').tuples).to eq [[1]] }
  specify('set') { expect(LA.of('[abc]').tuples).to eq [[1]] }
  specify('type') { expect(LA.of('\d').tuples).to eq [[1]] }
  specify('escape') { expect(LA.of('\n').tuples).to eq [[1]] }
  specify('property') { expect(LA.of('\p{ascii}').tuples).to eq [[1]] }
  specify('codepoint list') { expect(LA.of('\u{61 62 63}').tuples).to eq [[3]] }
  specify('anchor') { expect(LA.of('^a{2}$').tuples).to eq [[2]] }
  specify('free space') { expect(LA.of(/ a{2} /x).tuples).to eq [[2]] }
  specify('comment') { expect(LA.of('(?#comment)a').tuples).to eq [[1]] }
  specify('keep mark') { expect(LA.of('ab\Kcd').tuples).to eq [[4]] }
  specify('options group') { expect(LA.of('(?i:ab)').tuples).to eq [[2]] }

  specify('fixed quantifier') { expect(LA.of('a{5}').tuples).to eq [[5]] }
  specify('range quantifier') { expect(LA.of('a{2,4}').total_lengths).to eq [2, 3, 4] }
  specify('optional') { expect(LA.of('ab?').total_lengths).to eq [1, 2] }
  specify('zero repetitions') { expect(LA.of('a{0}b').tuples).to eq [[1]] }
  specify('nested quantifier') { expect(LA.of('(a{2}){2,3}').total_lengths).to eq [4, 6] }

  specify('alternation') do
    expect(LA.of('a|bc').tuples).to eq [[1], [2]]
  end

  specify('empty alternation branch') do
    expect(LA.of('a|').total_lengths).to eq [0, 1]
  end

  specify('group lengths are tracked per group') do
    expect(LA.of('(a{1,2})(b{1,3})').tuples).to eq [
      [2, 1, 1], [3, 1, 2], [3, 2, 1], [4, 1, 3], [4, 2, 2], [5, 2, 3]
    ]
  end

  specify('non-participating groups have nil length') do
    expect(LA.of('(a)|(b)').tuples).to eq [[1, nil, 1], [1, 1, nil]]
  end

  specify('optional non-participating group') do
    expect(LA.of('(a)(b)?').tuples).to eq [[1, 1, nil], [2, 1, 1]]
  end

  describe('backreferences') do
    specify('backref length equals the captured length') do
      expect(LA.of('(ab){2}\1').tuples).to eq [[6, 2]]
    end

    specify('correlated backref only allows matching totals') do
      analysis = LA.of('(a{1,3})\1')
      expect(analysis.tuples).to eq [[2, 1], [4, 2], [6, 3]]
      expect(analysis.total_lengths).to all(be_even)
    end

    specify('same capture referenced twice stays correlated') do
      expect(LA.of('(a{1,2})\1\1').tuples).to eq [[3, 1], [6, 2]]
    end

    specify('repeated capture takes the last result when referenced') do
      # group 1 holds the last iteration's capture, and \1 re-matches
      # exactly that, so e.g. [5, 1] and [4, 2] are not feasible
      expect(LA.of('(a|bb){2}\1').tuples).to eq [
        [3, 1], [4, 1], [5, 2], [6, 2]
      ]
    end

    specify('named backreference') do
      expect(LA.of('(?<x>a{1,2})\k<x>').tuples).to eq [[2, 1], [4, 2]]
    end

    specify('backref to non-participating group never matches') do
      # in Ruby/Onigmo, \1 fails to match when group 1 did not participate,
      # so only the branch where group 1 captured is feasible
      expect(LA.of('(?:(a)|b)\1').tuples).to eq [[2, 1]]
    end

    specify('quantified backref') do
      expect(LA.of('(a{1,2})\1{2}').tuples).to eq [[3, 1], [6, 2]]
    end

    specify('multiplexed named backreference') do
      expect(LA.of('(?:(?<x>a)|(?<x>bb))\k<x>').tuples).to eq [
        [2, 1, nil], [4, nil, 2]
      ]
    end

    specify('backref inside its own group refers to nothing yet') do
      expect(LA.of('(a\1?)').tuples).to eq [[1, 1]]
    end
  end

  describe('repeated captures') do
    specify('last iteration wins') do
      expect(LA.of('(a|bb){2}').tuples).to eq [[2, 1], [3, 1], [3, 2], [4, 2]]
    end

    specify('inner group capture persists across iterations') do
      # matching e.g. "ab" leaves group 2 at "a" from the first iteration
      expect(LA.of('((a)|b){2}').tuples).to eq [[2, 1, nil], [2, 1, 1]]
    end
  end

  describe('#group_lengths') do
    subject(:analysis) { LA.of('(?<x>a{1,2})(b{2,3})?') }

    it('returns feasible lengths by group number') do
      expect(analysis.group_lengths(1)).to eq [1, 2]
      expect(analysis.group_lengths(2)).to eq [2, 3]
    end

    it('returns feasible lengths by group name') do
      expect(analysis.group_lengths('x')).to eq [1, 2]
      expect(analysis.group_lengths(:x)).to eq [1, 2]
    end

    it('raises for unknown groups') do
      expect { analysis.group_lengths(3) }.to raise_error(ArgumentError)
      expect { analysis.group_lengths('y') }.to raise_error(ArgumentError)
    end
  end

  describe('group metadata') do
    subject(:analysis) { LA.of('(?<x>a)(b)(?<y>c)') }

    it('exposes group numbers and names') do
      expect(analysis.group_numbers).to eq [1, 2, 3]
      expect(analysis.group_names).to eq %w[x y]
    end
  end

  describe('Enumerable') do
    it('yields tuples') do
      expect(LA.of('a|bc').to_a).to eq [[1], [2]]
      expect(LA.of('a|bc').map(&:first)).to eq [1, 2]
    end
  end

  describe('::of') do
    it('works with Regexps') { expect(LA.of(/(a)\1/).tuples).to eq [[2, 1]] }
    it('works with Strings') { expect(LA.of('(a)\1').tuples).to eq [[2, 1]] }
    it('works with Expressions') do
      expect(LA.of(RP.parse('(a)\1')).tuples).to eq [[2, 1]]
    end
  end

  describe('Expression::Base#length_analysis') do
    it('returns the LengthAnalysis') do
      analysis = RP.parse('(a{1,2})\1').length_analysis
      expect(analysis).to be_a LA
      expect(analysis.tuples).to eq [[2, 1], [4, 2]]
    end
  end

  describe('non-analyzable structures') do
    specify('unbounded quantifiers') do
      ['a*', 'a+', 'a{2,}'].each do |source|
        expect { LA.of(source) }.to raise_error(LA::NotAnalyzable, /unbounded quantifier/)
      end
    end

    specify('unbounded quantifier on a group') do
      expect { LA.of('(ab)+') }.to raise_error(LA::NotAnalyzable, /unbounded quantifier/)
    end

    specify('subexp calls') do
      expect { LA.of('(a)\g<1>') }.to raise_error(LA::NotAnalyzable, /subexp call/)
      expect { LA.of('(?<x>a)\g<x>') }.to raise_error(LA::NotAnalyzable, /subexp call/)
    end

    specify('recursion levels') do
      expect { LA.of('(a)\k<1-1>') }.to raise_error(LA::NotAnalyzable, /subexp call/)
    end

    specify('lookarounds') do
      ['(?=a)', '(?!a)', '(?<=a)', '(?<!a)'].each do |source|
        expect { LA.of(source) }.to raise_error(LA::NotAnalyzable, /lookaround/)
      end
    end

    specify('conditionals') do
      expect { LA.of('(a)?(?(1)b|c)') }.to raise_error(LA::NotAnalyzable, /conditional/)
    end

    specify('absence groups') do
      expect { LA.of('(?~a)') }.to raise_error(LA::NotAnalyzable, /absence/)
    end

    specify('unresolved references') do
      exp = RP.parse('(a)\1').last
      exp.referenced_expressions = nil
      expect { LA.of(exp) }.to raise_error(LA::NotAnalyzable, /unresolved/)
    end
  end

  describe('state limit') do
    it('raises StateLimitExceeded instead of truncating') do
      expect { LA.of('(a|bb|ccc){4}', max_states: 3) }
        .to raise_error(LA::StateLimitExceeded, /state limit of 3/)
    end

    it('succeeds when the limit is sufficient') do
      expect(LA.of('(a|bb|ccc){4}', max_states: 100).total_lengths).to eq (4..12).to_a
    end

    it('deduplicates states, so large bounded quantifiers stay cheap') do
      expect(LA.of('a{100}').tuples).to eq [[100]]
    end
  end

  describe('exhaustive verification against Regexp') do
    it('matches all tuples of (a{1,3})\1') do
      expect_exhaustive_match('(a{1,3})\1', alphabet: %w[a], max_length: 6)
    end

    it('matches all tuples of (a|bb){2}\1') do
      expect_exhaustive_match('(a|bb){2}\1', alphabet: %w[a b], max_length: 6)
    end

    it('matches all tuples of (?<x>ab?)\k<x>') do
      expect_exhaustive_match('(?<x>ab?)\k<x>', alphabet: %w[a b], max_length: 4)
    end

    it('matches all tuples of (a)|(b)') do
      expect_exhaustive_match('(a)|(b)', alphabet: %w[a b], max_length: 2)
    end

    it('matches all tuples of (?:(a)|b)\1') do
      expect_exhaustive_match('(?:(a)|b)\1', alphabet: %w[a b], max_length: 2)
    end

    it('matches all tuples of ((a)|b){2}') do
      expect_exhaustive_match('((a)|b){2}', alphabet: %w[a b], max_length: 2)
    end

    it('matches all tuples of (ab?){1,2}(c)?') do
      expect_exhaustive_match('(ab?){1,2}(c)?', alphabet: %w[a b c], max_length: 7)
    end

    it('matches all tuples of (a){2}\1{2}') do
      expect_exhaustive_match('(a){2}\1{2}', alphabet: %w[a], max_length: 4)
    end
  end
end
