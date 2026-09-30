# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Regexp::RequiredLiterals do
  def analyze(input, *args, **kwargs)
    Regexp::RequiredLiterals.analyze(input, *args, **kwargs)
  end

  def literal(text, ci: false)
    Regexp::RequiredLiterals::Literal.new(text, case_insensitive: ci)
  end

  describe '.analyze' do
    it 'merges adjacent literals into one fragment' do
      expect(analyze(/foobar/)).to eq literal('foobar')
    end

    it 'combines sequence parts with AND' do
      condition = analyze(/foo\d+bar/)
      expect(condition.to_s).to eq '"foo" AND "bar"'
      expect(condition.match?('xxfooyybarzz')).to be true
      expect(condition.match?('xxfooyyzz')).to be false
      expect(condition.match?('xxyybarzz')).to be false
    end

    it 'combines alternation branches with OR' do
      condition = analyze(/foo|bar/)
      expect(condition.to_s).to eq '"foo" OR "bar"'
      expect(condition.match?('xfoo')).to be true
      expect(condition.match?('barx')).to be true
      expect(condition.match?('foba')).to be false
    end

    it 'factors common prefixes out of alternations' do
      condition = analyze(/cat|car/)
      expect(condition.to_s).to eq '"ca" AND ("t" OR "r")'
      expect(condition.match?('cat')).to be true
      expect(condition.match?('car')).to be true
      expect(condition.match?('cut')).to be false
    end

    it 'factors one branch being a prefix of another' do
      expect(analyze(/foo|foobar/)).to eq literal('foo')
    end

    it 'requires nothing from optional parts' do
      condition = analyze(/colou?r/)
      expect(condition.to_s).to eq '"colo" AND "r"'
      expect(condition.match?('color')).to be true
      expect(condition.match?('colour')).to be true
      expect(condition.match?('colr')).to be false
    end

    it 'requires nothing from star-quantified parts' do
      expect(analyze(/ab*c/).to_s).to eq '"a" AND "c"'
    end

    it 'repeats fragments for quantifiers with a minimum' do
      expect(analyze(/a{3}/)).to eq literal('aaa')
      expect(analyze(/a{2,4}b/).to_s).to eq '"aa" AND "aab"'
      expect(analyze(/(?:ab){2}c/)).to eq literal('ababc')
    end

    it 'does not over-merge fragments around open-ended quantifiers' do
      # /ab+c/ matches "abbc", which does not contain "abc"
      condition = analyze(/ab+c/)
      expect(condition.to_s).to eq '"ab" AND "bc"'
      expect(condition.match?('abbc')).to be true
      expect(condition.match?('abc')).to be true
    end

    it 'does not merge alternation prefixes with following literals' do
      # /(?:foo|foobar)x/ matches "foobarx", which does not contain "foox"
      condition = analyze(/(?:foo|foobar)x/)
      expect(condition.match?('foobarx')).to be true
    end

    it 'does not repeat fragments that are mere prefixes of a consumption' do
      # /(?:foo|foobar){2}/ matches "foobarfoo", which contains no "foofoo"
      condition = analyze(/(?:foo|foobar){2}/)
      expect(condition.match?('foobarfoo')).to be true
    end

    it 'does not require contents of negative lookaheads' do
      condition = analyze(/(?!foo)bar/)
      expect(condition).to eq literal('bar')
      expect(condition.match?('bar')).to be true
    end

    it 'does not require contents of negative lookbehinds' do
      expect(analyze(/(?<!foo)bar/)).to eq literal('bar')
    end

    it 'does not require contents of absence groups' do
      expect(analyze(/(?~foo)bar/)).to eq literal('bar')
    end

    it 'requires contents of positive lookaheads' do
      condition = analyze(/x(?=foo)/)
      expect(condition.match?('xfoo')).to be true
      expect(condition.match?('xfo')).to be false
    end

    it 'requires contents of positive lookbehinds' do
      condition = analyze(/(?<=ab)c/)
      expect(condition.match?('abc')).to be true
      expect(condition.match?('xbc')).to be false
    end

    it 'does not merge assertion contents with neighboring literals' do
      # (?=aba)ab matches "abab", which does not contain "abaab"
      condition = analyze(/(?=aba)ab/)
      expect(condition.match?('abab')).to be true
    end

    it 'honors option groups' do
      condition = analyze(/foo(?i:bar)baz/)
      expect(condition.match?('foobArbaz')).to be true
      expect(condition.match?('foobarbAz')).to be false
    end

    it 'honors option switches' do
      condition = analyze(/ab(?i)cd(?-i)ef/)
      expect(condition.to_s).to eq '"ab" AND "cd"(i) AND "ef"'
      expect(condition.match?('abCDef')).to be true
      expect(condition.match?('abCDeF')).to be false
    end

    it 'honors top-level ignorecase' do
      expect(analyze(/test/i).match?('xxTESTxx')).to be true
    end

    it 'matches case-insensitive fragments with regexp case folding' do
      # "ς".downcase is "ς", so a downcase-based filter would reject this
      condition = analyze(/σ/i)
      expect(condition.match?('ς')).to be true
      expect(condition.match?('Σ')).to be true
      expect(condition.match?('x')).to be false
    end

    it 'combines conditional branches with OR' do
      condition = analyze(/(x)?(?(1)yep|nope)/)
      expect(condition.to_s).to eq '"yep" OR "nope"'
      expect(condition.match?('yep')).to be true
      expect(condition.match?('nope')).to be true
      expect(condition.match?('neither')).to be false
    end

    it 'requires nothing from a conditional without else-branch' do
      expect(analyze(/(x)?(?(1)yep)/)).to eq Regexp::RequiredLiterals::Any.instance
    end

    it 'treats anchors and K as zero-width' do
      expect(analyze(/\Afoo\Kbar\z/)).to eq literal('foobar')
      expect(analyze(/\bfoo\b/)).to eq literal('foo')
    end

    it 'treats free-spacing and comments as zero-width' do
      expect(analyze(/f o o/x)).to eq literal('foo')
      expect(analyze(/foo(?#note)bar/)).to eq literal('foobar')
    end

    it 'derives fragments from escape sequences' do
      expect(analyze(/\x41\101/)).to eq literal('AA')
      expect(analyze(/\n\t/)).to eq literal("\n\t")
      expect(analyze(/\u{41 42}/)).to eq literal('AB')
      expect(analyze('\\j')).to eq literal('j')
    end

    it 'falls back to Any for unanalyzable constructs' do
      expect(analyze(/[abc]/)).to eq Regexp::RequiredLiterals::Any.instance
      expect(analyze(/\d+/)).to eq Regexp::RequiredLiterals::Any.instance
      expect(analyze(/\p{L}/)).to eq Regexp::RequiredLiterals::Any.instance
      expect(analyze(//)).to eq Regexp::RequiredLiterals::Any.instance
      expect(analyze(/[abc]/).match?('anything at all')).to be true
    end

    it 'still requires literals around unanalyzable constructs' do
      expect(analyze(/(a)\1/)).to eq literal('a')
      expect(analyze(/x[abc]y/).to_s).to eq '"x" AND "y"'
    end

    it 'accepts a String pattern with options' do
      condition = analyze('test', options: ::Regexp::IGNORECASE)
      expect(condition.match?('TEST')).to be true
    end

    it 'accepts an already-parsed expression' do
      expect(analyze(Regexp::Parser.parse(/foo/))).to eq literal('foo')
    end

    describe 'encodings' do
      it 'handles //n regexps with non-ascii bytes' do
        regexp = Regexp.new("abc\xC3\xA9".b, ::Regexp::NOENCODING)
        condition = Regexp::RequiredLiterals.analyze(regexp)
        expect(condition.match?("zzabc\xC3\xA9zz".b)).to be true
        expect(condition.match?('zzabczz'.b)).to be false
      end

      it 'handles //ni regexps with invalid UTF-8 bytes' do
        regexp = Regexp.new(%q{a\xE9b}.b, ::Regexp::NOENCODING | ::Regexp::IGNORECASE)
        condition = Regexp::RequiredLiterals.analyze(regexp)
        expect(condition.match?("zA\xE9Bz".b)).to be true
        expect(condition.match?('zzz'.b)).to be false
      end

      it 'handles US-ASCII regexps' do
        condition = analyze(Regexp.new('foo'.encode('US-ASCII')))
        expect(condition.match?('xxfooxx')).to be true
      end

      it 'never raises on candidates in incompatible encodings' do
        condition = analyze(/café/i)
        candidate = "CAF\xC9".dup.force_encoding('ISO-8859-1')
        expect { condition.match?(candidate) }.not_to raise_error
        expect(condition.match?(candidate)).to be true # conservative pass
      end

      it 'finds fragments byte-wise in binary candidates' do
        condition = analyze(/café/)
        expect(condition.match?("xxcaf\xC3\xA9xx".b)).to be true
        expect(condition.match?("xxcaf\xC3\xA9xx".encode('UTF-8'))).to be true
      end
    end
  end

  describe Regexp::RequiredLiterals::Condition do
    it 'combines conditions with & and |' do
      condition = (literal('a') | literal('b')) & literal('c')
      expect(condition.match?('ac')).to be true
      expect(condition.match?('bc')).to be true
      expect(condition.match?('ab')).to be false
      expect(condition.match?('xy')).to be false
    end

    it 'absorbs Any in conjunctions and is absorbed by Any in disjunctions' do
      any = Regexp::RequiredLiterals::Any.instance
      expect(any & literal('a')).to eq literal('a')
      expect(any | literal('a')).to eq any
    end
  end

  describe 'exhaustive comparison with Regexp' do
    alphabet = %w[a b c o f 0]
    strings = ['']
    1.upto(5) { |n| alphabet.repeated_permutation(n) { |p| strings << p.join } }

    patterns = [
      'foo', 'fo+', 'a.c', 'a{2,4}b', '(?:ab){2}c', 'ab*c', 'ab+c', 'a?b',
      'foo|bob', 'aba|bab', '(foo|bob)ab', '(a|b)+c', 'f(o+)b', '(a)\1',
      'foo\d+foo', '[abc]foo', 'foo[abc]', '\dfoo', 'foo\d',
      '(?!foo)bab', '(?<!foo)bab', '(?=boo)bo', '(?=aba)ab',
      'foo(?i:BOB)', 'ab(?i)C', '(?i)CAB', '(?i)foo',
      '^foo$', '\Afoo\z', 'foo\Kba', '\bfoo\b',
      '(f)?(?(1)o|b)', '\x61bc', '\141bc',
      '(?~foo)bab', 'a|', '|a', '', 'colou?r', 'cat|car|cow',
      '(?:ab)+c', '(?:ab){2,}c', 'a(?:bc)?f', 'f(?:a|ab)c',
      '(?:foo|foobar)f', 'f(?:foo|foobar)', '(?:fa|fb){2}c',
      '(?i:a)b', 'a(?i)b', '(?<=ab)c', '(?<=aba)b', 'f(?=foo)',
      'f(o)(b)', '(a|b)c(a|b)', 'aa?bb', '(?:a|b){2}c', '\babb\b',
      'a\Kb', '((a))b', '(?:a(?:b))c', 'a{2,}b', '(?:abc){2}',
    ]

    results = patterns.to_h do |pattern|
      regexp = Regexp.new(pattern)
      condition = Regexp::RequiredLiterals.analyze(regexp)
      false_negatives = []
      rejected = 0
      non_matching = 0

      strings.each do |string|
        ruby_match =
          begin
            regexp.match?(string)
          rescue Encoding::Error
            next
          end
        filter_pass = condition.match?(string)

        false_negatives << string if ruby_match && !filter_pass
        if ruby_match
          # nothing to check; the filter passed as required
        else
          non_matching += 1
          rejected += 1 unless filter_pass
        end
      end

      [pattern, { false_negatives: false_negatives,
                  rejected: rejected,
                  non_matching: non_matching }]
    end

    it 'produces no false negatives for any pattern and string' do
      failures = results.reject { |_, r| r[:false_negatives].empty? }
      expect(failures).to be_empty
    end

    it 'rejects a substantial share of non-matching inputs' do
      rejected = results.sum { |_, r| r[:rejected] }
      non_matching = results.sum { |_, r| r[:non_matching] }
      expect(non_matching).to be > 0
      expect(rejected).to be > non_matching / 2
    end

    it 'rejects non-matching inputs for every literal-bearing pattern' do
      strong = %w[foo foo\d+foo [abc]foo (?i)CAB (?:ab){2}c]
      strong.each do |pattern|
        expect(results[pattern][:rejected]).to be > 0
      end
    end
  end
end
