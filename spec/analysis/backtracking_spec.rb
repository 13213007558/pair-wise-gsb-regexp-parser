# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(RegexpParser::Backtracking) do
  def analyze(source, **opts)
    described_class.analyze(source, **opts)
  end

  describe '.analyze verdicts' do
    specify 'overlapping alternatives are reported as a risk' do
      result = analyze('(a|aa)*b')
      expect(result).to be_risk
      expect(result.findings.size).to eq 1
    end

    specify 'nested unbounded repetitions are reported as a risk' do
      expect(analyze('(a+)+b')).to be_risk
      expect(analyze('(a*)*b')).to be_risk
      expect(analyze('(\w+\s?)*$')).to be_risk
    end

    specify 'a nullable repetition body is reported as a risk' do
      expect(analyze('(a?){0,}b')).to be_risk
    end

    specify 'patterns without a provable witness are not called safe' do
      expect(analyze('a+b')).to be_no_risk_found
      expect(analyze('(a|b)*c')).to be_no_risk_found
      expect(analyze('[ab]+b')).to be_no_risk_found
    end

    specify 'unsupported constructs yield unanalyzable, never safe' do
      result = analyze('(a)\1+b')
      expect(result).to be_unanalyzable
      expect(result.limitations.join).to include('backreference')
    end

    specify 'named backreferences are unanalyzable too' do
      expect(analyze('(?<n>a+)x\k<n>')).to be_unanalyzable
    end

    specify 'a proven risk with a limitation stays a risk' do
      result = analyze('(?=x)(a+)+b')
      expect(result).to be_risk
      expect(result.limitations).not_to be_empty
    end

    specify 'an unparsable pattern is unanalyzable' do
      result = analyze('(a+')
      expect(result).to be_unanalyzable
    end
  end

  describe 'structurally close pairs' do
    risky    = ['(a|aa)*b', '(a+)+b', '(a*)*b', '(a|b|ab)*bc',
                '(a|b|ba)*ca', 'x(a|aa)+b', '(\w+\s?)*$', '(a?){0,}b']
    safe     = ['(?>a|aa)*b', '(a+)++b', '(a|aa)*a', '(a|b)*c',
                '(ab+)+b', '(a{1,3})+c', 'a*a*b', '(?:ab|aba)*x',
                '[ab]+b', '(a?)b']
    unknown  = ['(a)\1*b']

    risky.each do |source|
      specify "#{source.inspect} is risky" do
        expect(analyze(source, verify: false)).to be_risk
      end
    end

    safe.each do |source|
      specify "#{source.inspect} is no_risk_found" do
        expect(analyze(source, verify: false)).to be_no_risk_found
      end
    end

    unknown.each do |source|
      specify "#{source.inspect} is unanalyzable" do
        expect(analyze(source, verify: false)).to be_unanalyzable
      end
    end
  end

  describe 'atomic groups and possessive quantifiers' do
    specify 'an atomic group truncates ambiguity inside it' do
      expect(analyze('(?>(a+)+)b', verify: false)).to be_no_risk_found
      expect(analyze('((?>a+))+b', verify: false)).to be_no_risk_found
    end

    specify 'a possessive quantifier truncates ambiguity under it' do
      expect(analyze('(a+)++b', verify: false)).to be_no_risk_found
      expect(analyze('(a|aa)*+b', verify: false)).to be_no_risk_found
    end

    specify 'possessive sealing does not hide ambiguity outside the seal' do
      expect(analyze('a++(a|aa)*b', verify: false)).to be_risk
    end
  end

  describe 'finding range and witness' do
    let(:finding) { analyze('(a+)+b', verify: false).findings.first }

    specify 'reports the concrete AST range of the quantified expression' do
      expect(finding.range).to eq (0...5)
      expect(finding.expression_text).to eq '(a+)+'
    end

    specify 'exposes prefix, pump, suffix and a growing input family' do
      witness = finding.witness
      expect(witness.prefix).to eq ''
      expect(witness.pump).to eq 'a'
      expect(witness.suffix).to eq 'b'
      expect(witness.lengths).to all(be > 0)
      inputs = witness.inputs
      expect(inputs).to all(match(/\Aa+b\z/))
      expect(inputs.map(&:length)).to eq witness.lengths.map { |n| n + 1 }
    end

    specify 'includes a derivation reason' do
      expect(finding.reason).to include('repetition')
      expect(finding.reason).to include('suffix')
    end

    specify 'derives a concrete fixed prefix when one precedes the pump' do
      witness = analyze('x(a|aa)+b', verify: false).findings.first.witness
      expect(witness.prefix).to eq 'x'
    end
  end

  describe 'auxiliary verification' do
    specify 'runs only small inputs under a strict timeout and reports data' do
      verification = analyze('(a|aa)*b', timeout: 0.05,
                             pump_lengths: [12, 14]).findings.first.verification
      expect(verification.method).to eq :bounded_timeout
      expect(verification.timeout).to eq 0.05
      expect(verification.observations.map { |o| o[:repetitions] })
        .to eq [12, 14]
      expect(verification.summary).to be_a(String)
    end

    specify 'can be disabled for purely structural analysis' do
      finding = analyze('(a+)+b', verify: false).findings.first
      expect(finding.verification).to be_nil
    end
  end

  describe 'input forms' do
    specify 'accepts Regexp, String and parsed AST' do
      ast = Regexp::Parser.parse(/(a+)+b/)
      expect(analyze(ast, verify: false)).to be_risk
      expect(analyze(/(a+)+b/, verify: false)).to be_risk
      expect(analyze('(a+)+b', verify: false)).to be_risk
    end
  end

  describe 'free-spacing patterns' do
    specify 'a single repetition is linear even with x option' do
      expect(analyze(/a (a+) b/x, verify: false)).to be_no_risk_found
    end

    specify 'nested ambiguity is still detected with x option' do
      expect(analyze(/a ((a+)+) b/x, verify: false)).to be_risk
    end
  end
end
