# frozen_string_literal: true

require 'regexp_parser'

RSpec.describe Regexp::Optimizer do
  def optimize(source, *args)
    described_class.optimize(source, *args)
  end

  describe '.optimize' do
    it 'returns a Result with original, optimized and changes' do
      result = optimize('a+b')

      expect(result.original).to eq 'a+b'
      expect(result.optimized).to eq 'a++b'
      expect(result.changes).to contain_exactly(an_instance_of(described_class::Change))
      expect(result.skipped).to be_nil
    end

    it 'returns the source verbatim when nothing can be proven safe' do
      result = optimize('a+a')

      expect(result.optimized).to eq 'a+a'
      expect(result.changes).to be_empty
    end

    it 'accepts a Regexp and preserves its flags' do
      result = optimize(/a+b/)

      expect(result.optimized).to eq 'a++b'
      expect(Regexp.new(result.optimized).match('aaab')[0]).to eq 'aaab'
    end
 
    it 'round-trips the optimized pattern through the parser' do
      result = optimize('(a)+b')
      expect { Regexp::Parser.parse(result.optimized) }.not_to raise_error
    end

    it 'records the location and source snippets of each change' do
      change = optimize('a+b').changes.first

      expect(change.kind).to eq :possessive
      expect('a+b'[change.start, change.length]).to eq change.before
      expect(change.before).to eq '+'
      expect(change.after).to eq '++'
      expect(change.conditions).to all(be_a(String))
      expect(change.conditions.join).to include('disjoint')
    end
  end

  describe 'possessive quantifiers' do
    {
      'a+b'          => 'a++b',
      'ab+c'         => 'ab++c',
      '[ab]+c'       => '[ab]++c',
      '[a-c]+z'      => '[a-c]++z',
      '(?:ab)+c'     => '(?:ab)++c',
      '(ab)+c'       => '(ab)++c',
      'a|b+c'        => 'a|b++c',
      'b|a+c'        => 'b|a++c',
      'a+b|c'        => 'a++b|c',
      'a+[bc]'       => 'a++[bc]',
      '(a)+b'        => '(a)++b',
    }.each do |source, expected|
      it "rewrites #{source.inspect} to #{expected.inspect}" do
        expect(optimize(source).optimized).to eq expected
      end
    end

    [
      'a+a',            # first set of continuation overlaps
      'a*b',            # min 0 quantifier
      'a?b',            # min 0 quantifier
      'a{1,2}b',        # no possessive interval syntax in Ruby
      '(a|b)+b',        # alternatives inside repeated unit
      '(?:a?)+b',       # nullable repeated body
      '[^a]+a',         # negated set overlaps everything
      '[\\w]+a',        # unsupported character type
      '[[:alpha:]]+a',  # unsupported POSIX class
      '[abc&&b]+b',     # unsupported intersection
      '(b+){2}',        # outer repetition needs inner backtracking
      '(?:b+){2}',
      '(a*)+b',         # nested/nullable repetition
      '(?:(?:a+|z))?b', # enclosing min-0 group
      'a+?b',           # reluctant quantifier
      'a++b',           # already possessive
    ].each do |source|
      it "leaves #{source.inspect} unchanged" do
        expect(optimize(source).optimized).to eq source
      end
    end

    it 'does not treat {n,m}+ as a possessive interval (Ruby chains it)' do
      # In Ruby a{1,2}+ means (?:a{1,2})+ and is a different regex.
      expect(optimize('a{1,2}b').optimized).to eq 'a{1,2}b'
      expect { Regexp.new('a{1,2}+') }.not_to raise_error
      expect(/a{1,2}+/.match('aaa')[0]).to eq 'aaa'
    end
  end

  describe 'atomic groups' do
    {
      '(?:ab)'    => '(?>ab)',
      '(?:ab)c'   => '(?>ab)c',
      'x(?:ab)y'  => 'x(?>ab)y',
      '(ab)'      => '(?>(ab))',
      '(ab)c'     => '(?>(ab))c',
      '(?<n>ab)'  => '(?>(?<n>ab))',
    }.each do |source, expected|
      it "rewrites #{source.inspect} to #{expected.inspect}" do
        expect(optimize(source).optimized).to eq expected
      end
    end

    it 'keeps capture numbering and names when wrapping' do
      result = optimize('(?<word>ab)')
      re = Regexp.new(result.optimized)
      m = re.match('ab')

      expect(m[:word]).to eq 'ab'
      expect(m.names).to eq ['word']
      expect(m.offset(1)).to eq [0, 2]
    end

    [
      '(?:a|b)',   # alternatives
      '(?:a?)',    # quantifier inside
      '(?:a)*',    # min-0 quantified group
      '(?>ab)',    # already atomic
    ].each do |source|
      it "leaves #{source.inspect} unchanged" do
        expect(optimize(source).optimized).to eq source
      end
    end
  end

  describe 'global bail-outs' do
    {
      'a+b\\Kc'         => 'keep mark',
      '(?i:a)+b'        => 'inline option',
      '(?<x>a)\\g<x>'   => 'subexpression call',
      '(a)(?(1)b|c)'    => 'conditional',
    }.each do |source, _hint|
      it "leaves #{source.inspect} completely untouched" do
        result = optimize(source)

        expect(result.optimized).to eq source
        expect(result.changes).to be_empty
        expect(result.skipped).to be_a(String)
      end
    end

    it 'refuses case-insensitive Regexps' do
      result = optimize(/a+b/i)

      expect(result.optimized).to eq 'a+b'
      expect(result.skipped).to include('case-insensitive')
    end

    it 'transforms independent branches when no global bail applies' do
      # No recursive call here; both branches can be analyzed on their own.
      expect(optimize('a+b|c+d').optimized).to eq 'a++b|c++d'
    end
  end

  describe 'counterexamples that must stay unchanged' do
    # The classic greedy/possessive divergence: possessive refuses to give
    # back the last 'a', so the regex fails while greedy succeeds.
    it 'does not possessivize a+ when the continuation starts with a' do
      expect(/a+a/.match('aa')).not_to be_nil
      expect(/a++a/.match('aa')).to be_nil
      expect(optimize('a+a').optimized).to eq 'a+a'
    end

    # Greedy capture content differs across repetitions; an inner possessive
    # would change which iteration the outer capture keeps.
    it 'does not change (b+){2}, whose capture relies on inner backtracking' do
      greedy    = /(b+){2}/
      possessive = /(b++){2}/

      expect(greedy.match('bbbb').captures).to eq ['b']
      expect(possessive.match('bbbb')).to be_nil
      expect(optimize('(b+){2}').optimized).to eq '(b+){2}'
    end

    it 'does not change c+(b*)... where a nullable group hides overlap' do
      source = 'c+(b*){1,2}[b-c]{1,2}'
      expect(optimize(source).optimized).to eq source
    end

    it 'does not change the content captured inside a min-0 outer group' do
      source = '((?:(?:[a-c]+|x)|z)?)(?>a){1,3}'
      expect(optimize(source).optimized).to eq source
    end

    it 'sees past an alternation that ends in the quantified unit' do
      expect(/(a+|b)a/.match('aa')).not_to be_nil
      expect(/(a++|b)a/.match('aa')).to be_nil

      expect(optimize('(a+|b)a').optimized).to eq '(a+|b)a'
      expect(optimize('(?:ab+|z)b').optimized).to eq '(?:ab+|z)b'
      expect(optimize('(a+|)a').optimized).to eq '(a+|)a'
      # a disjoint character after the alternation is still safe
      expect(optimize('(a+|b)c').optimized).to eq '(a++|b)c'
    end
  end
end
