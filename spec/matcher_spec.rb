# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Regexp::Matcher) do
  def match(pattern, string, pos = 0)
    described_class.new(pattern).match(string, pos)
  end

  # Overall match and final captures must agree with Ruby's Regexp.
  # All positions are character offsets (like MatchData#begin/#end).
  describe 'parity with Regexp#match' do
    cases = [
      # [pattern, string, (optional) start position]
      ['abc', 'xxabcy'],
      ['abc', 'ab'],
      ['', 'abc'],
      ['a|bc|d', 'xxd'],
      ['a|bc|d', 'abc'],
      ['[a-c][^d-f]', 'xacz'],
      ['[a-c][^d-f]', 'adz'],
      ['[^a]+', 'aaabbb'],
      ['a{2,4}', 'aaaaa'],
      ['a{2,4}', 'a'],
      ['a{2,4}', 'aa'],
      ['a{2,}', 'aaaa'],
      ['a{3}', 'aaaa'],
      ['a??', 'a'],
      ['a??', ''],
      ['(ab|a)(b?)', 'ab'],
      ['(a|b)*c', 'ababc'],
      ['(a|b)*c', 'c'],
      ['(a+)(b+)?', 'aabbb'],
      ['(a+)(b+)?', 'aa'],
      ['colou?r', 'color'],
      ['colou?r', 'colour'],
      ['a+?a', 'aaa'],
      ['(a+?)(a*)', 'aaa'],
      ['[a-z]{2,3}?', 'abcd'],
      ['a{2,3}?b', 'aaaaab'],
      ['a{2,3}+', 'aaaaa'],
      ['(?:a{2,3})?', 'abcd'],
      ['x(y(z))?', 'xyz'],
      ['x(y(z))?', 'x'],
      ['((a)|(b))+', 'ab'],
      ['(a)(b)?(c)', 'ac'],
      ['(a)(b)?(c)', 'abc'],
      ['(a?)*', 'aa'],
      ['(a?)*', 'b'],
      ['(a*)+', 'b'],
      ['(a*)+', 'aaa'],
      ['((a*)*)*', 'b'],
      ['(ab|cd)+e', 'abcdabe'],
      ['(x|y)*z', 'xyxz'],
      ['()', 'a'],
      ['(?:(a)|b)+', 'ab'],
      ['^(ab)+$', 'abab'],
      ['^(ab)+$', "ab\nab"],
      ['b$', "ab\nb"],
      ['^b', "ab\nb"],
      ['\\A(a+)\\z', 'aaa'],
      ['\\A(a+)\\z', "aaa\n"],
      ['a\\Z', "a\n"],
      ['a\\Z', 'a'],
      ['\\bfoo\\b', 'a foo b'],
      ['\\bfoo\\b', 'foobar'],
      ['\\Boo\\B', 'food'],
      ['\\Boo\\B', 'oo'],
      ['\\Ga+', 'aaa'],
      ['\\Ga+', 'xaa'],
      ['a+', 'aaa', 1],
      ['\\Gb', 'ab', 1],
      ['\\Ga', 'ab', 1],
      ['(a+)', 'aaa', -2],
    ]

    cases.each do |pattern, string, pos|
      it "matches #{pattern.inspect} against #{string.inspect}#{" from #{pos}" if pos}" do
        ruby = Regexp.new(pattern).match(string, pos || 0)
        ours = match(pattern, string, pos || 0)

        if ruby.nil?
          expect(ours).to be_nil
        else
          expect(ours).not_to be_nil
          expect(ours.matched).to eq(ruby[0])
          expect(ours.range).to eq(ruby.begin(0)...ruby.end(0))
          expect(ours.captures).to eq(ruby.captures)
          (1..ours.group_count).each do |n|
            expected = ruby.begin(n) && (ruby.begin(n)...ruby.end(n))
            expect(ours.capture_range(n)).to eq(expected)
          end
        end
      end
    end
  end

  describe 'capture histories' do
    it 'records every iteration of a repeated group' do
      m = match('(a)+', 'aaa')
      expect(m.range).to eq(0...3)
      expect(m.history(1)).to eq([0...1, 1...2, 2...3])
      expect(m.capture_range(1)).to eq(2...3) # final capture, like MatchData
    end

    it 'records nested repetitions per group' do
      m = match('((ab)+)', 'zababz')
      expect(m.range).to eq(1...5)
      expect(m.history(1)).to eq([1...5])
      expect(m.history(2)).to eq([1...3, 3...5])
      expect(m.captures).to eq(%w[abab ab])
    end

    it 'records empty captures of empty matches' do
      m = match('(a*)*', 'b')
      expect(m.matched).to eq('')
      expect(m.range).to eq(0...0)
      expect(m.captures).to eq([''])
      expect(m.history(1)).to eq([0...0])
    end

    it 'reports no history for groups that never participated' do
      m = match('(a|b)*', '')
      expect(m.matched).to eq('')
      expect(m.captures).to eq([nil])
      expect(m.history(1)).to eq([])
    end

    it 'drops iterations that were backtracked out of' do
      m = match('(a)+a', 'aaa')
      expect(m.matched).to eq('aaa')
      # the third iteration was rolled back to let the trailing literal match
      expect(m.history(1)).to eq([0...1, 1...2])
      expect(m.capture_range(1)).to eq(1...2)
    end

    it 'drops captures from failed alternatives' do
      m = match('(a(b)|ac)d', 'acd')
      expect(m.captures).to eq(['ac', nil])
      expect(m.history(1)).to eq([0...2])
      expect(m.history(2)).to eq([])
    end

    it 'drops group spans recorded on abandoned inner paths' do
      m = match('(a+|ab)c', 'abc')
      # the a+ alternative recorded [0...1] before failing at the literal c
      expect(m.history(1)).to eq([0...2])
    end

    it 'keeps earlier captures when later iterations use other branches' do
      m = match('(?:(a)|b)+', 'ab')
      expect(m.captures).to eq(['a'])
      expect(m.history(1)).to eq([0...1])
    end

    it 'resets captures between search start positions' do
      m = match('(a)b', 'aab')
      expect(m.range).to eq(1...3)
      expect(m.history(1)).to eq([1...2])
    end
  end

  describe 'positions' do
    it 'reports character offsets, not byte offsets' do
      m = match('(é)(b)', 'aébz')
      expect(m.range).to eq(1...3)
      expect(m.history(1)).to eq([1...2])
      expect(m.history(2)).to eq([2...3])
      ruby = /(é)(b)/.match('aébz')
      expect(m.range).to eq(ruby.begin(0)...ruby.end(0))
    end
  end

  describe 'unsupported expressions' do
    unsupported = [
      '\\d', '\\w', '\\s', '.',
      '(?=a)', '(?!a)', '(?<=a)', '(?<!a)',
      '(?>a)', '(?~a)',
      '(a)\\1', '(?<n>a)\\k<n>',
      '\\K', '\\p{Alpha}', '\\R',
      '[[:alpha:]]', '[a&&b]',
      '(?#comment)',
      '(a)?(?(1)b|c)',
      'a++', 'a?+', 'a*+',
    ]

    unsupported.each do |pattern|
      it "rejects #{pattern.inspect} before matching" do
        expect { described_class.new(pattern) }
          .to raise_error(Regexp::Matcher::UnsupportedError)
      end
    end

    it 'rejects case-insensitive patterns' do
      expect { described_class.new(/ab/i) }
        .to raise_error(Regexp::Matcher::UnsupportedError, /case-insensitive/)
    end

    it 'rejects inline option switches' do
      expect { described_class.new('a(?i)b') }
        .to raise_error(Regexp::Matcher::UnsupportedError)
    end
  end

  describe 'API' do
    it 'accepts Regexp, String, and Root patterns' do
      expect(described_class.new(/a+/).match('aaa').matched).to eq('aaa')
      expect(described_class.new('a+').match('aaa').matched).to eq('aaa')
      root = Regexp::Parser.parse('a+')
      expect(described_class.new(root).match('aaa').matched).to eq('aaa')
    end

    it 'exposes MatchData-like accessors' do
      m = described_class.match('(a)(b)?', 'ab')
      expect(m.matched).to eq('ab')
      expect(m.to_s).to eq('ab')
      expect(m[0]).to eq('ab')
      expect(m[1]).to eq('a')
      expect(m[2]).to eq('b')
      expect(m.to_a).to eq(['ab', 'a', 'b'])
      expect(m.group_count).to eq(2)
    end

    it 'supports named captures like plain ones' do
      m = match('(?<word>a+)', 'aaa')
      expect(m.capture(1)).to eq('aaa')
      expect(m.history(1)).to eq([0...3])
    end

    it 'returns nil when there is no match' do
      expect(match('a+', 'bbb')).to be_nil
    end
  end
end
