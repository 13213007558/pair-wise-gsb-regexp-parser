# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Regexp::Matcher) do
  def compare_with_ruby(pattern, string)
    expected = Regexp.new(pattern).match(string)
    actual = Regexp::Matcher.new(pattern).match(string)

    if expected.nil?
      expect(actual).to(be_nil, "expected no match for /#{pattern}/ on #{string.inspect}")
    else
      expect(actual).not_to(be_nil, "expected a match for /#{pattern}/ on #{string.inspect}")
      expect([actual.begin(0), actual.end(0)])
        .to(eq([expected.begin(0), expected.end(0)]),
            "match span differs for /#{pattern}/ on #{string.inspect}")
      expect(actual.to_s).to eq expected[0]
      expect(actual.captures).to eq expected.captures
    end
  end

  # All corpus strings are ASCII so that Ruby's byte offsets and the
  # matcher's character offsets coincide.
  patterns = [
    '',
    'abc',
    'a+', 'a*', 'a?', 'a{2,3}', 'a{2,}', 'a{2}',
    # NOTE: a{2,}? is absent because the parser normalizes chained
    # quantifiers (interval + ?) into an implicit passive group.
    'a+?', 'a*?', 'a??',
    'a|bc', 'a|b|c',
    '(a)(b)?', '(a)(b)(c)?', '(a)?a', '(a)*?',
    '(a|b)*c', '((a)|b)+', '(a(b)?)+', '(a|b|ab)*',
    '(a*)*', '(a*)+', '(a?)*', '(a?)+', '(a*)*b', '(a?)*b',
    '(a+)(a*)', '(a*)(a*)', '(a+)+b', '(a|b)+b',
    '(a|ab)(c|bcd)(d*)', '(ab|a)(b)?', '((a)(b)?)*', '((a)b)*c',
    '(?:ab|a)+b', '(?:a(?:b)?)+',
    '[a-c]+', '[^a-c]+', '[abc]*x', '[a-cx-z]+',
    '^a+', 'a+$', '^$', '\\Aabc\\z', '\\A(a|b)+\\Z', '\\A\\z',
    'a?a?a?aaa', 'x(a|b)*y',
  ].freeze

  strings = [
    '', 'a', 'aa', 'aaa', 'aaaa', 'b', 'ab', 'ba', 'abc', 'aab',
    'abab', 'abcd', 'xabcy', 'cabc', 'aaaab', 'bcdf', 'xyz', 'ac',
    "ab\ncd", "ab\n", 'aaab',
  ].freeze

  describe 'overall match and final captures, compared with Ruby' do
    patterns.each do |pattern|
      strings.each do |string|
        it "agrees with Ruby for /#{pattern}/ on #{string.inspect}" do
          compare_with_ruby(pattern, string)
        end
      end
    end
  end

  describe 'capture history' do
    it 'records every iteration of a repeated group' do
      match = Regexp::Matcher.new('(a(b)?)+').match('abab')

      expect(match.to_a).to eq ['abab', 'ab', 'b']
      expect(match.history(1)).to eq [[0, 2], [2, 4]]
      expect(match.history(2)).to eq [[1, 2], [3, 4]]
    end

    it 'records nested groups independently' do
      match = Regexp::Matcher.new('((a)b)*c').match('ababc')

      expect(match.to_a).to eq ['ababc', 'ab', 'a']
      expect(match.history(1)).to eq [[0, 2], [2, 4]]
      expect(match.history(2)).to eq [[0, 1], [2, 3]]
    end

    it 'keeps the captures of a final empty iteration, like Ruby' do
      match = Regexp::Matcher.new('(a?)*').match('aaa')

      expect(match.captures).to eq ['']
      expect(match.history(1)).to eq [[0, 1], [1, 2], [2, 3], [3, 3]]
    end

    it 'records an empty span for a group that only matches empty' do
      match = Regexp::Matcher.new('(a?)*').match('b')

      expect(match.to_a).to eq ['', '']
      expect(match.begin(0)).to eq 0
      expect(match.end(0)).to eq 0
      expect(match.history(1)).to eq [[0, 0]]
    end

    it 'matches empty at the offset when the pattern can match empty' do
      match = Regexp::Matcher.new('(a*)').match('bbb', 2)

      expect(match.to_a).to eq ['', '']
      expect(match.span(1)).to eq [2, 2]
    end

    it 'drops captures from alternatives that failed during backtracking' do
      match = Regexp::Matcher.new('(a)b|(a)c').match('ac')

      expect(match.captures).to eq [nil, 'a']
      expect(match.history(1)).to eq []
      expect(match.history(2)).to eq [[0, 1]]
    end

    it 'drops nested captures from a failed alternative' do
      match = Regexp::Matcher.new('(a(b)c|a)b').match('ab')

      expect(match.captures).to eq ['a', nil]
      expect(match.history(1)).to eq [[0, 1]]
      expect(match.history(2)).to eq []
    end

    it 'drops captures from repetition iterations that were backtracked' do
      match = Regexp::Matcher.new('(a|b)+b').match('ab')

      expect(match.to_a).to eq ['ab', 'a']
      expect(match.history(1)).to eq [[0, 1]]
    end

    it 'drops captures from a group that a lazy quantifier never entered' do
      match = Regexp::Matcher.new('(a)*?').match('aaa')

      expect(match.to_a).to eq ['', nil]
      expect(match.history(1)).to eq []
    end

    it 'exposes all histories at once' do
      match = Regexp::Matcher.new('(a(b)?)+').match('abab')

      expect(match.histories).to eq(1 => [[0, 2], [2, 4]], 2 => [[1, 2], [3, 4]])
    end

    it 'returns the whole-match span for history(0)' do
      match = Regexp::Matcher.new('a+').match('baa')

      expect(match.history(0)).to eq [[1, 3]]
    end
  end

  describe 'positions' do
    it 'reports character offsets, not byte offsets' do
      # (ä|ö)+ on xäöy
      pattern = "(\u00e4|\u00f6)+"
      string = "x\u00e4\u00f6y"
      match = Regexp::Matcher.new(pattern).match(string)

      expect(match.begin(0)).to eq 1
      expect(match.end(0)).to eq 3
      expect(match.to_s).to eq string[1..2]
      expect(match.history(1)).to eq [[1, 2], [2, 3]]
      # the same span measured in bytes would be 1...5:
      expect(string[0...match.end(0)].bytesize).to eq 5
      # Ruby's MatchData#begin/#end are character offsets as well:
      ruby = Regexp.new(pattern).match(string)
      expect([ruby.begin(0), ruby.end(0)]).to eq [match.begin(0), match.end(0)]
    end
  end

  describe '#match' do
    it 'returns nil when the pattern does not match' do
      expect(Regexp::Matcher.new('a+').match('bbb')).to be_nil
    end

    it 'searches left to right and finds the leftmost match' do
      match = Regexp::Matcher.new('b+').match('aabbbab')

      expect(match.span(0)).to eq [2, 5]
    end

    it 'starts searching at the given character offset' do
      match = Regexp::Matcher.new('abc').match('abcabc', 3)

      expect(match.span(0)).to eq [3, 6]
    end

    it 'raises IndexError for an out-of-bounds offset' do
      expect { Regexp::Matcher.new('a').match('abc', 4) }.to raise_error(IndexError)
      expect { Regexp::Matcher.new('a').match('abc', -1) }.to raise_error(IndexError)
    end

    it 'exposes the searched string and MatchData-like accessors' do
      match = Regexp::Matcher.new('(a)(b)?').match('xa')

      expect(match.string).to eq 'xa'
      expect(match.to_s).to eq 'a'
      expect(match[0]).to eq 'a'
      expect(match[1]).to eq 'a'
      expect(match[2]).to be_nil
      expect(match.begin(2)).to be_nil
      expect(match.end(2)).to be_nil
      expect(match.span(2)).to be_nil
    end
  end

  describe 'pattern input' do
    it 'accepts a Regexp' do
      expect(Regexp::Matcher.new(/ab+/).match('abb').to_s).to eq 'abb'
    end

    it 'accepts a parsed Root expression' do
      root = RP.parse('(a|b)+')

      expect(Regexp::Matcher.new(root).match('ba').to_a).to eq ['ba', 'a']
    end

    it 'counts the capture groups' do
      expect(Regexp::Matcher.new('(a)((b)|c)').group_count).to eq 3
      expect(Regexp::Matcher.new('abc').group_count).to eq 0
    end
  end

  describe 'unsupported syntax' do
    unsupported = [
      '(?=a)a', '(?!a)a', '(?<=a)b', '(?<!a)b', # lookaround
      '(a)\\1',                                # backreference
      '(?>a)',                                   # atomic group
      'a++', 'a?+',                              # possessive quantifiers
      '\\ba', 'a\\B', '\\Ga',              # word boundary / match start anchors
      '\\d', '\\w', '\\s', '.',            # character types
      '\\n', '\\.',                          # escape sequences
      '\\p{alpha}',                            # unicode property
      '[[:alpha:]]',                             # posix class
      '[a&&b]',                                  # set intersection
      '(?i)abc', '(?i:abc)',                     # option switches
      '(?#comment)',                             # comment
      'a\\Kb',                                 # keep
    ]

    unsupported.each do |pattern|
      it "rejects #{pattern.inspect} before matching" do
        expect { Regexp::Matcher.new(pattern) }
          .to raise_error(Regexp::Matcher::UnsupportedError)
      end
    end

    it 'rejects case-insensitive regexps' do
      expect { Regexp::Matcher.new(/abc/i) }
        .to raise_error(Regexp::Matcher::UnsupportedError)
    end

    it 'raises an error that is a Regexp::Parser::Error' do
      expect { Regexp::Matcher.new('(a)\\1').match('aa') }
        .to raise_error(Regexp::Parser::Error)
    end
  end
end
