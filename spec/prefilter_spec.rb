# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Regexp::Prefilter) do
  PF = Regexp::Prefilter

  describe 'branch conditions' do
    let(:condition) { PF.derive(/(?:alpha|beta).*end/) }

    it 'derives an AND of the branch OR and the trailing literal' do
      expect(condition).to be_a(PF::All)
      any, trailing = condition.children
      expect(any).to be_a(PF::Any)
      expect(any.literals.map(&:text)).to eq %w[alpha beta]
      expect(trailing).to eq PF::Literal.new('end', false, 16, 19)
    end

    it 'renders as a readable expression' do
      expect(condition.to_s).to eq '("alpha" | "beta") & "end"'
    end

    it 'reports the source range of the contributing literals' do
      expect(condition.source_range).to eq 3...19
      expect(condition.children.first.source_range).to eq 3...13
      expect(PF.derive(/a*/).source_range).to be_nil
    end

    it 'accepts only texts containing one branch and the tail' do
      expect(condition.match?('xxalphayyendzz')).to be true
      expect(condition.match?('beta end')).to be true
      expect(condition.match?('alpha')).to be false
      expect(condition.match?('gamma end')).to be false
      expect(condition.match?('alphabeta')).to be false
    end

    it 'supports === for case/when usage' do
      expect(condition === 'alpha-end').to be true
      expect(condition === 'nope').to be false
    end
  end

  describe 'input types' do
    it 'accepts Regexp, String, and Expression inputs' do
      expect(PF.derive('abc').to_s).to eq '"abc"'
      expect(PF.derive(/abc/).to_s).to eq '"abc"'
      expect(PF.derive(Regexp::Parser.parse(/abc/)).to_s).to eq '"abc"'
    end
  end

  describe 'nullable patterns' do
    it 'ignores optional parts' do
      expect(PF.derive(/a?b/).to_s).to eq '"b"'
      expect(PF.derive(/(?:abc)?def/).to_s).to eq '"def"'
      expect(PF.derive(/x{0,3}y/).to_s).to eq '"y"'
    end

    it 'returns a tautology when nothing is required' do
      expect(PF.derive(/a*/)).to be_tautology
      expect(PF.derive(/(a|)/)).to be_tautology
      expect(PF.derive(/\d+/)).to be_tautology
      expect(PF.derive(/[^a]/)).to be_tautology
      expect(PF.derive(/a*/).match?('anything')).to be true
      expect(PF.derive(/a*/).literal_count).to eq 0
    end

    it 'does not merge literals across nullable parts' do
      expect(PF.derive(/a(?:b)?c/).to_s).to eq '"a" & "c"'
      expect(PF.derive(/a.c/).to_s).to eq '"a" & "c"'
    end
  end

  describe 'case folding' do
    it 'marks literals of case-insensitive patterns' do
      condition = PF.derive(/abc/i)
      expect(condition.to_s).to eq '"abc"/i'
      expect(condition.match?('XXABCXX')).to be true
      expect(condition.match?('abd')).to be false
    end

    it 'respects local option groups' do
      condition = PF.derive(/a(?i:b)c/)
      expect(condition.to_s).to eq '"a" & "b"/i & "c"'
      expect(condition.match?('aBc')).to be true
      expect(condition.match?('ABc')).to be false
    end

    it 'respects option switches' do
      condition = PF.derive(/a(?i)b/)
      expect(condition.to_s).to eq '"a" & "b"/i'
      expect(condition.match?('aB')).to be true
      expect(condition.match?('Ab')).to be false
    end

    it 'folds non-ascii case like the regexp engine' do
      condition = PF.derive(/stra\u00DFe/i)
      expect(condition.match?('STRASSE')).to be true
      expect(condition.match?("xxSTRA\u00DFExx")).to be true
    end
  end

  describe 'conservative constructs' do
    it 'treats backreferences as opaque' do
      expect(PF.derive(/(abc)x\1/).to_s).to eq '"abcx"'
      expect(PF.derive(/(a)?\1b/).to_s).to eq '"b"'
    end

    it 'ignores negative lookarounds but keeps positive ones' do
      expect(PF.derive(/(?!foo)bar/).to_s).to eq '"bar"'
      expect(PF.derive(/(?<=ab)cd/).to_s).to eq '"ab" & "cd"'
      expect(PF.derive(/(?<!ab)cd/).to_s).to eq '"cd"'
    end

    it 'does not merge literals across zero-width assertions' do
      condition = PF.derive(/(?=foo)foo/)
      expect(condition.to_s).to eq '"foo" & "foo"'
      expect(condition.match?('foo')).to be true
    end

    it 'treats conditionals as branch alternatives' do
      expect(PF.derive('(a)(?(1)b|c)d').to_s).to eq '"a" & ("b" | "c") & "d"'
      expect(PF.derive('(a)(?(1)b)d').to_s).to eq '"a" & "d"'
    end

    it 'reads single-char sets and escape sequences' do
      expect(PF.derive(/[a]b/).to_s).to eq '"ab"'
      expect(PF.derive(/a\x62c/).to_s).to eq '"abc"'
      expect(PF.derive(/[a-z]b/).to_s).to eq '"b"'
      expect(PF.derive(/[^a]b/).to_s).to eq '"b"'
    end
  end

  describe 'options' do
    it 'drops literals shorter than min_length' do
      expect(PF.derive(/(?:alpha|beta).*end/, min_length: 4).to_s)
        .to eq '"alpha" | "beta"'
      expect(PF.derive(/(?:alpha|beta).*end/, min_length: 6)).to be_tautology
    end

    it 'collapses to a tautology beyond max_literals' do
      expect(PF.derive(/a.b.c.d/, max_literals: 2)).to be_tautology
      expect(PF.derive(/a.b.c.d/, max_literals: 4).to_s)
        .to eq '"a" & "b" & "c" & "d"'
    end
  end

  describe 'encoding' do
    it 'matches unicode literals' do
      expect(PF.derive(/h\u00E9llo/).match?("xxh\u00E9lloxx")).to be true
    end

    it 'never rejects on encoding mismatch' do
      condition = PF.derive(/h\u00E9llo/)
      expect(condition.match?("\xFF\xFEh\u00E9llo".b)).to be true
    end
  end

  describe 'soundness on random small inputs' do
    it 'never rejects a text that the regexp matches' do
      rng = Random.new(20_260_920)
      atoms = ['a', 'b', 'c', 'ab', '.', '\\d', '[ab]', '[^a]', '\u00E9', '\\n']
      build = nil
      build = lambda do |depth|
        if depth <= 0
          atoms.sample(random: rng)
        else
          case rng.rand(8)
          when 0 then "#{build.call(depth - 1)}#{build.call(depth - 1)}"
          when 1 then "#{build.call(depth - 1)}|#{build.call(depth - 1)}"
          when 2 then "(?:#{build.call(depth - 1)})"
          when 3 then "(#{build.call(depth - 1)})"
          when 4 then "(?i:#{build.call(depth - 1)})"
          when 5 then "(?:#{atoms.sample(random: rng)})#{['?', '*', '+', '{2}'].sample(random: rng)}"
          when 6 then "(?>#{build.call(depth - 1)})"
          else atoms.sample(random: rng)
          end
        end
      end

      fixed = [
        '(?:alpha|beta).*end', '(a|b)*c', '(?i:Ab)c', 'a(?i)b',
        '(abc)x\\1', '(a)?\\1b', '(a)(?(1)b|c)d', '(?=foo)bar', '(?!foo)bar',
        '(?<=ab)cd', '(?<!ab)cd', 'a\\Kb', '\\Aabc\\z', '^a$b', '(?~x)y',
        '[a]b', '[^a]b', '[a-z]b', 'a\\x62c', '\\u0041b', '\\n\\t',
        '(?<n>a|b)\\k<n>', 'a{2,3}b', '(?:ab|cd)+e', '((a))b', '\\bword\\b',
        'stra\u00DFe', '(?i:stra\u00DFe)', '\u00E9x', '()a', '(?:)b', 'a()b',
      ]
      patterns = fixed + Array.new(150) { build.call(2) }

      alphabet = ['a', 'b', 'c', 'd', 'A', 'B', 'x', '1', ' ', "\n", "\u00E9", "\u00DF"]
      texts = Array.new(80) do
        Array.new(rng.rand(0..10)) { alphabet.sample(random: rng) }.join
      end
      texts += ['', 'alphaXend', 'abc', 'ABC', 'word', 'stra\u00DFe', 'STRASSE']

      checked = 0
      patterns.each do |pattern|
        regexp = begin
          Regexp.new(pattern)
        rescue RegexpError
          next
        end
        condition = PF.derive(pattern)
        texts.each do |text|
          next unless regexp.match?(text)

          checked += 1
          expect(condition.match?(text)).to be(true),
            "prefilter #{condition} rejected #{text.inspect} " \
            "which is matched by #{regexp.inspect}"
        end
      end
      expect(checked).to be > 100
    end
  end
end
