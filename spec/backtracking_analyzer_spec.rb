# frozen_string_literal: true

require 'timeout'
require_relative 'spec_helper'

RSpec.describe 'Regexp::BacktrackingAnalyzer' do
  def analyzer_class
    Regexp::BacktrackingAnalyzer
  end

  describe '.analyze' do
    it 'reports overlapping repetition branches with a concrete range and witness' do
      pattern = /x(?:a|aa)+!/
      result = analyzer_class.analyze(pattern)

      expect(result.status).to eq(analyzer_class::RISK_FOUND)
      expect(result.risky?).to eq(true)
      expect(result.risks.length).to eq(1)

      risk = result.risks.first
      expect(risk.range).to eq([1, 9])
      expect(risk.ambiguous_ranges).to include([4, 1], [6, 2])
      expect(risk.suffix_range).to eq([10, 1])
      expect(risk.witness.prefix).to eq('x')
      expect(risk.witness.repeatable).to eq('a')
      expect(risk.witness.suffix).to eq('!')
      expect(risk.witness.example(12)).to eq('xaaaaaaaaaa!')
      expect(risk.reason).to include('overlapping', 'suffix', 'atomic')
    end

    it 'distinguishes the same branches sealed by an atomic group' do
      result = analyzer_class.analyze(/x(?>a|aa)+!/)

      expect(result.status).to eq(analyzer_class::NO_RISK_FOUND)
      expect(result.risks).to be_empty
    end

    it 'distinguishes the same branches sealed by a possessive quantifier' do
      result = analyzer_class.analyze(/x(?:a|aa)++!/)

      expect(result.status).to eq(analyzer_class::NO_RISK_FOUND)
      expect(result.risks).to be_empty
    end

    it 'does not report disjoint repeated branches as risky' do
      result = analyzer_class.analyze(/(?:a|b)+!/)

      expect(result.status).to eq(analyzer_class::NO_RISK_FOUND)
      expect(result.risks).to be_empty
    end

    it 'does not use nested stars as the only signal' do
      risky = analyzer_class.analyze(/(?:[a-z]+_?)+!/)
      sealed = analyzer_class.analyze(/(?>[a-z]+_?)+!/)
      disjoint = analyzer_class.analyze('(?:[ab]*)+!')

      expect(risky.status).to eq(analyzer_class::RISK_FOUND)
      expect(sealed.status).to eq(analyzer_class::NO_RISK_FOUND)
      expect(disjoint.status).to eq(analyzer_class::NO_RISK_FOUND)
    end

    it 'handles overlapping bounded repetitions and their atomic counterpart' do
      risky = analyzer_class.analyze(/(?:a|aa){2,}+!/)
      sealed = analyzer_class.analyze(/(?:(?>a|aa){2,})+!/)

      expect(risky.status).to eq(analyzer_class::RISK_FOUND)
      expect(risky.risks.first.witness.repeatable).to eq('a')
      expect(sealed.status).to eq(analyzer_class::NO_RISK_FOUND)
    end

    it 'reports a required suffix after optional following terms' do
      result = analyzer_class.analyze(/(?:a|aa)+b?x/)

      expect(result.status).to eq(analyzer_class::RISK_FOUND)
      expect(result.risks.first.witness.suffix).to eq('x')
    end

    it 'marks constructs outside the conservative proof as unanalyzable rather than safe' do
      result = analyzer_class.analyze(/(?:a|aa)+(?!x)/)

      expect(result.status).to eq(analyzer_class::UNANALYZABLE)
      expect(result.risky?).to eq(false)
      expect(result.unsupported.first.range).to eq([9, 5])
    end

    it 'does not present an unsupported pattern as proven or safe' do
      result = analyzer_class.analyze(/(?=z)(?:a|aa)+!/)

      expect(result.status).to eq(analyzer_class::UNANALYZABLE)
      expect(result.risks).to be_empty
      expect(result.unsupported.map(&:range)).to eq([[0, 5]])
    end
  end

  describe '#verify_witness!' do
    it 'checks a generated witness family with small inputs and a strict timeout' do
      analyzer = analyzer_class.new
      pattern = /x(?:a|aa)+!/
      risk = analyzer.analyze(pattern).risks.first

      expect do
        analyzer.verify_witness!(pattern, risk.witness,
                                 lengths: [8, 10], timeout: 0.01)
      end.not_to raise_error
    end

    it 'raises for a hand-written witness that does not exercise the pattern' do
      analyzer = analyzer_class.new
      pattern = /x(?:a|aa)+!/
      witness = analyzer_class::Witness.new('z', 'a', '!', 'invalid')

      expect do
        analyzer.verify_witness!(pattern, witness, lengths: [8], timeout: 0.01)
      end.to raise_error(RuntimeError, /witness/)
    end

    it 'uses only a small witness length for the auxiliary check' do
      analyzer = analyzer_class.new
      pattern = /x(?:a|aa)+!/
      risk = analyzer.analyze(pattern).risks.first

      expect do
        analyzer.verify_witness!(pattern, risk.witness,
                                 lengths: [8], timeout: 0.01)
      end.not_to raise_error
      expect(risk.witness.example(8)).to eq('xaaaaaa!')
    end
  end
end
