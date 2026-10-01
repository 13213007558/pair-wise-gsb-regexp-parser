# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Regexp::BacktrackingAnalysis do
  specify 'accepts a parsed AST' do
    result = described_class.analyze(Regexp::Parser.parse('(a|aa)*z'))

    expect(result).to be_vulnerable
    expect(result.findings.first.locations.first.expression).to be_a(Regexp::Expression::Group::Capture)
  end

  specify 'detects exponential ambiguity through lazy nesting' do
    result = described_class.analyze('(?:a*)*?z')

    expect(result.findings.first.severity).to eq(:exponential)
    expect(result.findings.first.witness.repeatable).to eq('a')
  end

  specify 'does not treat possessive repetition as an outer ambiguity source' do
    expect(described_class.analyze('(a*+)*z')).to be_safe
  end

  specify 'uses step counts that grow for nested alternations' do
    root = Regexp::Parser.parse('(a|aa)*z')
    finding = described_class.analyze(root, nil, [6, 8, 10]).findings.first

    expect(finding.trend.step_counts.each_cons(2).all? { |left, right| right > left * 2 }).to be(true)
  end

  specify 'returns unknown rather than claiming safety for recursive calls' do
    expect(described_class.analyze('(?<x>a|\g<x>)*z')).to be_unknown
  end
end
