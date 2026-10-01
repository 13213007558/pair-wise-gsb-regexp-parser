# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Regexp::BacktrackingAnalysis do

  def analyze(pattern, sizes = [6, 8, 10, 12])
    described_class.analyze(pattern, nil, sizes)
  end

  def steps(pattern, input)
    root = Regexp::Parser.parse(pattern)
    described_class::Interpreter.steps(root, input, root.options || {})
  end

  specify 'detects exponential ambiguity from nested quantifiers' do
    result = analyze('(a*)*z')

    expect(result).to be_vulnerable
    finding = result.findings.first
    expect(finding.severity).to eq(:exponential)
    expect(finding.witness.prefix).to eq('')
    expect(finding.witness.repeatable).to eq('a')
    expect(result_inputs(finding)).to all(be_a(String))
    expect(steps('(a*)*z', 'a' * 12 + finding.witness.suffix).to_f /
      steps('(a*)*z', 'a' * 6 + finding.witness.suffix)).to be > 60
    expect(finding.trend.growth).to eq(:exponential)
    expect(finding.locations.map(&:starts_at)).to eq([0, 1])
  end

  specify 'points at an ambiguous ordered alternation' do
    result = analyze('(a|aa)*z')

    expect(result.findings.first.severity).to eq(:exponential)
    location = result.findings.first.locations.last
    expect(location.expression).to be_a(Regexp::Expression::Alternation)
    expect(location.starts_at).to eq(1)
    expect(location.length).to eq(4)
  end

  specify 'detects polynomial overlap between adjacent quantifiers' do
    result = analyze('a*a*z')

    expect(result).to be_vulnerable
    finding = result.findings.first
    expect(finding.severity).to eq(:polynomial)
    expect(finding.witness.repeatable).to eq('a')
    expect(finding.trend.step_counts.each_cons(2).all? { |left, right| right > left }).to be(true)
    expect(finding.locations.map { |location| [location.starts_at, location.length] }).to eq([[0, 2], [2, 2]])
  end

  specify 'treats lazy quantifiers as backtracking-capable' do
    result = analyze('a*?a*?z')

    expect(result.findings.first.severity).to eq(:polynomial)
  end

  specify 'handles character sets and a failure suffix' do
    result = analyze('[ab]*[ab]*c')

    expect(result.findings.first.severity).to eq(:polynomial)
    expect(result.findings.first.witness.repeatable).to eq('a')
    expect(result.findings.first.witness.suffix).to eq('cz')
  end

  specify 'does not report disjoint ordered alternatives without repetition' do
    result = analyze('(a|aa)b')

    expect(result).to be_safe
  end

  specify 'atomic groups suppress outer backtracking ambiguity' do
    expect(analyze('(?>a*a*)z')).to be_safe
    expect(analyze('(?>a*)a')).to be_safe
  end

  specify 'possessive quantifiers suppress outer backtracking ambiguity' do
    expect(analyze('a*+a*z')).to be_safe
    expect(analyze('(?:a|aa)*+b')).to be_safe
  end

  specify 'bounded nullable repetitions do not grow with input length' do
    expect(analyze('(a?){20}z')).to be_safe
  end

  specify 'bounded repetitions of unbounded bodies can be polynomial' do
    result = analyze('(a*){2}z')

    expect(result.findings.first.severity).to eq(:polynomial)
  end

  specify 'returns unknown for assertions' do
    result = analyze('(?=a)z')

    expect(result).to be_unknown
    expect(result.unsupported.severity).to eq(:unknown)
    expect(result.unsupported.locations.first.starts_at).to eq(0)
  end

  specify 'returns unknown for recursive calls' do
    result = analyze('(?<x>a|\g<x>)*z')

    expect(result).to be_unknown
  end

  specify 'returns unknown for conditional groups' do
    result = analyze('(a)(?(1)b|c)z')

    expect(result).to be_unknown
  end

  specify 'the interpreter counts attempts independently of wall-clock time' do
    root = Regexp::Parser.parse('a*a*z')
    counts = [6, 8, 10].map do |size|
      described_class::Interpreter.steps(root, 'a' * size + 'Z', root.options || {})
    end

    expect(counts).to eq([63, 99, 143])
    expect(counts.each_cons(2).all? { |left, right| right > left }).to be(true)
  end

  def result_inputs(finding)
    finding.trend.sizes.map do |size|
      finding.witness.prefix + (finding.witness.repeatable * size) + finding.witness.suffix
    end
  end
end
