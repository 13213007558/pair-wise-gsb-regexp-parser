# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Regexp::RequiredLiteral) do
  describe('.of') do
    it 'builds an OR condition for branches and an AND for following text' do
      condition = described_class.of('(?:alpha|beta).*end')

      expect(condition).to be_a(Regexp::RequiredLiteral::And)
      branch_condition = condition.conditions.first
      expect(branch_condition).to be_a(Regexp::RequiredLiteral::Or)
      expect(branch_condition.conditions.map(&:literal)).to eq %w[alpha beta]
      expect(branch_condition.source_range).to eq [3, 13]
      expect(condition.conditions.last).to have_attributes(
        literal: 'end',
        source_range: [16, 19]
      )

      expect(condition.match?('alpha end')).to be true
      expect(condition.match?('beta to the end')).to be true
      expect(condition.match?('gamma end')).to be false
    end

    it 'keeps the required literal from a nullable pattern' do
      condition = described_class.of('a*b')

      expect(condition).to be_a(Regexp::RequiredLiteral::Literal)
      expect(condition.literal).to eq 'b'
      expect(condition.source_range).to eq [2, 3]
      expect(condition.match?('b')).to be true
      expect(condition.match?('aaa')).to be false
    end

    it 'supports a local ignorecase option' do
      condition = described_class.of('(?i:Ab)c')

      expect(condition).to be_a(Regexp::RequiredLiteral::Literal)
      expect(condition).to have_attributes(
        literal: 'c',
        ignorecase: false,
        source_range: [7, 8]
      )
      expect(condition.match?('aBxC')).to be false
      expect(condition.match?('aBxc')).to be true
    end

    it 'does not infer multicharacter ignorecase literals because folding can expand' do
      condition = described_class.of(/ff/i)

      expect(condition).to be_always
      expect(condition.match?('ﬀ')).to be true
    end

    it 'drops an empty alternative but keeps surrounding required literals' do
      condition = described_class.of('a(?:b|)')

      expect(condition).to be_a(Regexp::RequiredLiteral::Literal)
      expect(condition.literal).to eq 'a'
    end

    it 'treats a quantified group with an empty alternative as nullable' do
      condition = described_class.of('(?:a|)+b')

      expect(condition).to be_a(Regexp::RequiredLiteral::Literal)
      expect(condition.literal).to eq 'b'
      expect(condition.match?('b')).to be true
    end

    it 'drops zero-repetition text but keeps following required literals' do
      condition = described_class.of('a{0}b')

      expect(condition).to be_a(Regexp::RequiredLiteral::Literal)
      expect(condition.literal).to eq 'b'
    end

    it 'does not infer a literal from a character set member' do
      condition = described_class.of('[ab]c')

      expect(condition).to be_a(Regexp::RequiredLiteral::Literal)
      expect(condition.literal).to eq 'c'
    end

    it 'supports a single non-ASCII ignorecase literal on modern Ruby' do
      condition = described_class.of(/å/i)

      expect(condition).to be_a(Regexp::RequiredLiteral::Literal)
      expect(condition.ignorecase).to be true
      expect(condition.match?('Å')).to be true
    end

    it 'treats a backreference as locally unknown' do
      condition = described_class.of('(a)\1b')

      expect(condition).to be_a(Regexp::RequiredLiteral::And)
      expect(condition.conditions.map(&:literal)).to eq %w[a b]
    end

    it 'keeps text after a negative lookahead' do
      condition = described_class.of('(?!x)y')

      expect(condition).to be_a(Regexp::RequiredLiteral::Literal)
      expect(condition.literal).to eq 'y'
    end

    it 'does not use a quantified negative lookahead as a reliable condition' do
      condition = described_class.of('(?!x)*y')

      expect(condition).to be_a(Regexp::RequiredLiteral::Literal)
      expect(condition.literal).to eq 'y'
      expect(condition.match?('xy')).to be true
    end

    it 'includes text required by a positive lookahead' do
      condition = described_class.of('(?=x)y')

      expect(condition.conditions.map(&:literal)).to eq %w[x y]
    end

    it 'ignores literals shorter than the configured minimum length' do
      condition = described_class.of('abc|de', min_literal_length: 3)

      expect(condition).to be_always
    end

    it 'caps the condition complexity' do
      condition = described_class.of('(?:abc|def)ghi|jkl', max_complexity: 5)

      expect(condition).to be_always
    end

    it 'uses source ranges for escaped literals' do
      condition = described_class.of('\x61b')

      expect(condition).to have_attributes(
        literal: 'ab',
        source_range: [0, 5]
      )
    end

    it 'includes the quantifier in a repeated literal source range' do
      condition = described_class.of('(?:ab){3}c')

      expect(condition.source_range).to eq [0, 10]
    end

    it 'preserves BINARY encoding for high byte escapes' do
      regexp = Regexp.new('\x80b', Regexp::NOENCODING)
      condition = described_class.of(regexp)
      literals = condition.each_literal.to_a

      expect(literals.first.literal).to eq("\x80".b)
      expect(literals.first.literal.encoding).to eq Encoding::ASCII_8BIT
      expect(condition.match?("\x80b".b)).to be true
    end

    it 'preserves UTF-8 encoding for Unicode escapes' do
      regexp = Regexp.new('\u0080b')
      condition = described_class.of(regexp)
      literals = condition.each_literal.to_a

      expect(literals.first.literal).to eq("\u0080b")
      expect(literals.first.literal.encoding).to eq Encoding::UTF_8
      expect(condition.match?("\u0080b")).to be true
      expect(condition.match?("\x80b".b)).to be false
    end

    it 'does not raise for invalid UTF-8 input' do
      condition = described_class.of(/a/)
      string = "a\xff".dup.force_encoding(Encoding::UTF_8)

      expect { condition.match?(string) }.not_to raise_error
      expect(condition.match?(string)).to be true
    end
  end

  describe 'soundness against small random strings' do
    patterns = [
      /alpha|beta/,
      /(?:alpha|beta).*end/,
      /a*b/,
      /a?b?c/,
      /(?i:Ab)c/,
      /(?:x|y){2,4}z/,
      /foo(?=bar).*baz/,
      /(?!x)*y/,
      /[ab]*c/,
      /(?:cat|dog)s?/,
      /start.+(?:middle|center).*finish/,
      /a\b?b/,
      /(?=x)a?b/,
      /(?:ab){3}c/,
      /(?:a|b){2}c/,
      /(?:a|)+b/
    ]

    alphabet = ('a'..'z').to_a + %w[A B c . * space alpha beta end x y]
    srand 4242
    samples = Array.new(2000) do
      Array.new(rand(0..18)) { alphabet.sample }.join
    end

    patterns.each_with_index do |pattern, index|
      it "never rejects a string matched by pattern #{index}" do
        condition = described_class.of(pattern)

        samples.each do |string|
          next unless pattern.match?(string)

          expect(condition.match?(string)).to be(true),
            "condition #{condition.inspect} rejected matching #{string.inspect}"
        end
      end
    end
  end
end
