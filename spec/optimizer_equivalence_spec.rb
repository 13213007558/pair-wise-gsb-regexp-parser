# frozen_string_literal: true

require 'regexp_parser'

# The generated patterns intentionally contain nested/redundant quantifiers,
# for which Ruby emits warnings; they are irrelevant to these comparisons.

RSpec.describe Regexp::Optimizer, 'exhaustive short-alphabet equivalence' do
  around do |example|
    original = $VERBOSE
    $VERBOSE = nil
    example.run
    $VERBOSE = original
  end

  ALPHABET = %w[a b c].freeze
  MAX_LENGTH = 5
  STRINGS = (0..MAX_LENGTH).flat_map do |length|
    ALPHABET.product(*[ALPHABET] * length).map(&:join)
  end

  def signature(regexp, string)
    match = regexp.match(string)
    return nil unless match

    groups = (1...match.length).map do |index|
      match[index].nil? ? nil : [match.begin(index), match.end(index)]
    end
    named = match.names.uniq.sort.map do |name|
      [name, match.offset(name)]
    end

    [match.begin(0), match.end(0), named, groups]
  end

  def expect_equivalent!(source, optimized)
    original = Regexp.new(source)
    rewritten = Regexp.new(optimized)

    STRINGS.each do |string|
      before = signature(original, string)
      after  = signature(rewritten, string)
      next if before == after

      expect(after).to eq(before)
    end
  end

  TEMPLATES = %w[
    a+b a+bc ab+c (a)+b (ab)+c (?:ab)+c [ab]+c [a-c]+c
    a|b+c b|a+c a+b|c (a)b+c (ab)(cd)+e ((a)b)+c a(b+c)d
    (ab)+ ab+ (ab)c x(ab)y (a)(b) ^a+b a+b$ a+(b*) c+(b*)x
    a+[bc] [bc]+[ab]
  ].freeze

  it 'keeps full MatchData for every changed hand-picked template' do
    TEMPLATES.each do |template|
      result = described_class.optimize(template)
      next if result.optimized == template

      expect_equivalent!(template, result.optimized)
    end
  end

  GUARDED = %w[
    a+a (b+){2} (?:b+){2} c+(b*){1,2}[b-c]{1,2}
    (?:(?:a+|z))?a [ab]+b
  ].freeze

  it 'leaves every greedy-capture counterexample unchanged' do
    GUARDED.each do |pattern|
      expect(described_class.optimize(pattern).optimized).to eq(pattern)
    end
  end

  it 'shows the guarded rewrites are observably different in Ruby' do
    expect(/a+a/.match('aa')).not_to be_nil
    expect(/a++a/.match('aa')).to be_nil

    expect(/(b+){2}/.match('bbbb').captures).to eq ['b']
    expect(/(b++){2}/.match('bbbb')).to be_nil

    expect(/c+(b*){1,2}[b-c]{1,2}/.match('ccc')).not_to be_nil
    expect(/c++(b*){1,2}[b-c]{1,2}/.match('ccc')).to be_nil
  end

  it 'is equivalent for hundreds of generated structural patterns' do
    atoms = %w[a b c]
    sets = ['[ab]', '[a-c]', '[bc]', '[^a]', '[^c]', '[a]', '[abc]']
    quants = ['', '?', '*', '+', '{2}', '{1,2}']
    rng = Random.new(707)

    term = lambda do |depth|
      if depth < 2 && rng.rand < 0.35
        body = Array.new(rng.rand(1..3)) { term.call(depth + 1) }.join
        wrap = ['(?:%s)', '(%s)', '(?<n>%s)'].sample(random: rng)
        format(wrap, body) + quants.sample(random: rng)
      else
        base = rng.rand < 0.5 ? atoms.sample(random: rng) : sets.sample(random: rng)
        base + quants.sample(random: rng)
      end
    end

    sequence = ->(depth) { Array.new(rng.rand(1..3)) { term.call(depth) }.join }

    tested = 0
    4000.times do
      body = sequence.call(0)
      source = case rng.rand(3)
               when 0
                 # alternation in a group, possibly followed by more atoms
                 # (this is where continuation must cross the alternation)
                 group = "(?:#{body}|#{sequence.call(0)})#{quants.sample(random: rng)}"
                 rng.rand < 0.6 ? group + sequence.call(0) : group
               when 1
                 capture = "(#{body}|#{sequence.call(0)})"
                 rng.rand < 0.6 ? capture + sequence.call(0) : capture
               else
                 body
               end

      result = described_class.optimize(source)
      next if result.optimized == source

      tested += 1
      expect_equivalent!(source, result.optimized)
      break if tested >= 300
    end

    expect(tested).to be >= 100
  end
end
