# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Regexp::Parser::Language do
  let(:alphabet) { ['a', 'b', '1'] }

  def self.proves_inclusion(left, right, alphabet)
    it "proves #{left.inspect} is included in #{right.inspect}" do
      result = described_class.subset(left, right, alphabet)
      expect(result).to be_included
    end
  end

  def self.proves_counterexample(left, right, alphabet, counterexample)
    it "returns a verified counterexample for #{left.inspect} vs #{right.inspect}" do
      result = described_class.subset(left, right, alphabet)
      expect(result).to be_not_included
      expect(result.counterexample).to eq(counterexample)
      expect(Regexp.new(left).match?(counterexample)).to eq(true)
      expect(Regexp.new(right).match?(counterexample)).to eq(false)
      expect(result.direction).to eq(:left_accepted_right_rejected)
    end
  end

  proves_inclusion 'a+', 'a*', ['a']
  proves_inclusion '[ab]+', '(?:a|b)+', ['a', 'b']
  proves_inclusion 'a{2}', 'aaa?', ['a']
  proves_inclusion '\\d', '[0-9]', ['0', 'a']
  proves_inclusion 'a', '(?i:A)', ['a', 'A']
  proves_inclusion '(?x:a b)', 'ab', ['a', 'b', ' ']

  proves_counterexample 'a', 'b', ['a', 'b'], 'a'
  proves_counterexample 'a{2}', 'a{3}', ['a'], 'aa'
  proves_counterexample '[0-9]{2}', '[0-9]{3}', ['0', '1'], '00'

  it 'finds the other direction during equivalence checks' do
    result = described_class.equivalent('a', 'b', ['a', 'b'])
    expect(result).to be_not_included
    expect(result.direction).to eq(:left_accepted_right_rejected)

    result = described_class.equivalent('b', 'a', ['a', 'b'])
    expect(result.direction).to eq(:right_accepted_left_rejected)
  end

  it 'handles start and end anchors' do
    expect(described_class.subset('^a$', '\\Aa\\z', ['a'])).to be_included
    expect(described_class.equivalent('^a$', '\\Aa\\z', ['a'])).to be_equivalent
  end

  it 'honors local multiline, ignorecase, and extended options' do
    expect(described_class.equivalent('(?m:^a)', '(?m:^a)', ['a'])).to be_equivalent
    expect(described_class.equivalent('(?i:a)', '[aA]', ['a', 'A'])).to be_equivalent
    expect(described_class.subset('(?x:a b)', '(?x:ab)', ['a', 'b', ' '])).to be_included
  end

  unsupported = ['(a)\\1', '(?=a)', 'a++', 'a\\b', '(?>a)', '\\g<x>']
  unsupported.each do |pattern|
    it "returns unknown for unsupported #{pattern.inspect}" do
      result = described_class.equivalent(pattern, pattern, ['a'])
      expect(result).to be_unknown
    expect(result.reason).not_to be_nil
    end
  end

  it 'reports unknown when the state limit is exceeded' do
    result = described_class.equivalent('(?:a|b)*', '(?:a|b)*', ['a', 'b'], max_states: 4)
    expect(result).to be_unknown
    expect(result.reason).to include('state')
  end

  it 'rejects invalid alphabets' do
    expect { described_class.equivalent('a', 'a', 1) }.to raise_error(ArgumentError)
    expect { described_class.equivalent('a', 'a', ['ab']) }.to raise_error(ArgumentError)
  end
end
