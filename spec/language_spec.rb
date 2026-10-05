# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Language inclusion and equivalence' do
  let(:ab) { %w[a b] }
  let(:abc) { %w[a b c] }

  describe Regexp::Parser do
    it 'proves inclusion of a+ in [ab]+' do
      result = described_class.includes?('a+', '[ab]+', ab)
      expect(result).to be_included
      expect(result).to be_proven
      expect(result.counterexample).to be_nil
    end

    it 'disproves inclusion of [ab]+ in a+ with the shortest witness' do
      result = described_class.includes?('[ab]+', 'a+', ab)
      expect(result).to be_not_included
      expect(result.counterexample).to eq('b')
      expect(result.direction).to eq(:left_to_right)
      expect(result.accepted_by).to eq(:left)
      expect(result.rejected_by).to eq(:right)
    end

    it 'returns a counterexample genuinely accepted by one side only' do
      result = described_class.includes?('[ab]+', 'a+', ab)
      word = result.counterexample
      expect(/\A(?:[ab]+)\z/).to match(word)
      expect(/\A(?:a+)\z/).not_to match(word)
    end

    it 'orders counterexamples shortest then codepoint order' do
      result = described_class.includes?('[abc]', 'a', abc)
      expect(result.counterexample).to eq('b')
      result2 = described_class.includes?('.', 'a', abc)
      expect(result2.counterexample).to eq('b')
    end

    it 'treats equivalent regexps as equivalent' do
      pairs = [
        ['ab?', 'a|ab'],
        ['a|b', '[ab]'],
        ['(a|b)*', '[ab]*'],
        ['[0-9]+', '\\d+'],
      ]
      pairs.each do |left, right|
        result = described_class.equivalent?(left, right, abc + %w[0 1])
        expect(result).to be_equivalent, [left, right].inspect
      end
    end

    it 'reports a right-to-left counterexample for non-equivalent patterns' do
      result = described_class.equivalent?('a+', '[ab]+', ab)
      expect(result).to be_not_included
      expect(result.counterexample).to eq('b')
      expect(result.direction).to eq(:right_to_left)
      expect(result.accepted_by).to eq(:right)
      expect(result.rejected_by).to eq(:left)
    end

    it 'supports character sets, concatenation, branches and quantifiers' do
      expect(described_class.includes?('[a-c]{2}', '[abc][abc]', abc)).to be_included
      expect(described_class.includes?('a(b|c)', 'ab|ac', abc)).to be_included
      expect(described_class.includes?('a{2,3}', 'aaa?', abc)).to be_included
    end

    it 'handles possessive and reluctant quantifiers like greedy ones' do
      expect(described_class.equivalent?('a*+', 'a*', ab)).to be_equivalent
      expect(described_class.equivalent?('a+?', 'a+', ab)).to be_equivalent
    end

    it 'supports atomic groups' do
      expect(described_class.equivalent?('(?>ab)', 'ab', ab)).to be_equivalent
    end

    describe 'anchors' do
      it 'equates ^a$, \Aa\z and a on the supported alphabet' do
        expect(described_class.equivalent?('^a$', '\\Aa\\z', abc)).to be_equivalent
      end

      it 'keeps \z stricter than $ over an alphabet containing newlines' do
        alpha = ['a', 'b', "\n"]
        result = described_class.includes?('a\\z', 'a$', alpha)
        expect(result).to be_included
        reverse = described_class.includes?('a$', 'a\\z', alpha)
        expect(reverse).to be_not_included
        expect(reverse.counterexample).to eq("a\n")
      end

      it 'does not let an inner $ in a group drop a trailing newline' do
        alpha = ['a', 'b', "\n"]
        expect(described_class.includes?('(?:a$)', 'a\\z', alpha)).to be_included
        expect(described_class.includes?('a$', '(?:a$)', alpha)).to be_not_included
      end

      it 'honours multiline mode for line anchors' do
       alpha = ['a', 'b', "\n"]
        result = described_class.equivalent?(/a\n/m, /a$\n/m, alpha)
       expect(result).to be_equivalent
        newline_result = described_class.includes?(/^a$/m, /a/m, alpha)
        expect(newline_result).to be_not_included
        expect(newline_result.counterexample).to eq("a\n")
      end
    end

    describe 'local options' do
      it 'applies case folding inside local option groups' do
        expect(described_class.equivalent?('(?i:a)', '[Aa]', %w[A a b])).to be_equivalent
        expect(described_class.equivalent?('(?i)[ab]', '[AaBb]', %w[A a B b])).to be_equivalent
      end

      it 'keeps case sensitivity outside local option groups' do
        result = described_class.includes?('a(?i:b)', '[AB]', %w[A a B b])
        expect(result).to be_not_included
      end
    end

    describe 'unsupported features' do
      def expect_unknown(pattern, alphabet = %w[a b])
        inclusion = Regexp::Parser.includes?(pattern, 'a*', alphabet)
        equivalence = Regexp::Parser.equivalent?(pattern, pattern, alphabet)
        expect(inclusion).to be_unknown
        expect(equivalence).to be_unknown
      end

      it 'is unknown for backreferences' do
        expect_unknown('(a)\\1')
      end

      it 'is unknown for recursive subpattern calls' do
        expect_unknown('(a)\\g<1>')
      end

      it 'is unknown for lookarounds and other assertions' do
        expect_unknown('(?=a)')
        expect_unknown('(?!a)')
        expect_unknown('(?<=a)')
        expect_unknown('(?<!a)')
      end

      it 'is unknown for word boundaries and keep marks' do
        expect_unknown('a\\bb')
        expect_unknown('a\\Kb')
      end

      it 'is unknown for linebreak and grapheme constructs' do
        expect_unknown('\\R')
        expect_unknown('\\X')
      end

      it 'is unknown for conditionals' do
        expect_unknown('(?(1)a|b)')
      end

      it 'is unknown for the absence group' do
        expect_unknown('(?~a)')
      end
    end

    describe 'state limits' do
      it 'returns unknown instead of guessing when the NFA is too large' do
      result = described_class.includes?('a{1000}', 'a*', ab, max_states: 16)
      expect(result).to be_unknown
      expect(result.reason).to eq(:state_limit_exceeded)
    end
    end

    describe 'arguments' do
      it 'rejects an empty alphabet' do
        expect { described_class.includes?('a', 'a', []) }.to raise_error(ArgumentError)
      end

      it 'rejects alphabet entries that are not single characters' do
        expect { described_class.includes?('a', 'a', ['ab']) }.to raise_error(ArgumentError)
      end

      it 'accepts Regexp objects and carries their flags' do
        expect(described_class.equivalent?(/a/i, '[Aa]', %w[A a b])).to be_equivalent
      end
    end
  end
end
