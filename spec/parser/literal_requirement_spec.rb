# frozen_string_literal: true

require 'spec_helper'

RSpec.describe('literal requirements') do
  Any = RP::LiteralRequirement::Any
  And = RP::LiteralRequirement::And
  Or = RP::LiteralRequirement::Or
  Contains = RP::LiteralRequirement::Contains

  def condition_tree(condition)
    case condition
    when Any then :any
    when Contains
      condition.casefold ? [:contains_i, condition.string] : [:contains, condition.string]
    when And then [:and, condition.children.map { |child| condition_tree(child) }]
    when Or then [:or, condition.children.map { |child| condition_tree(child) }]
    end
  end

  it 'builds AND/OR conditions from required sequence pieces and alternatives' do
    condition = RP.literal_requirement(/foo(?:bar|baz)/)

    expect(condition_tree(condition)).to eq(
      [:and, [
        [:contains, 'foo'],
        [:or, [[:contains, 'bar'], [:contains, 'baz']]],
      ]]
    )
    expect(condition.match?('xx foobar xx')).to eq(true)
    expect(condition.match?('xx FOObaz xx')).to eq(false)
    expect(condition.match?('nothing relevant')).to eq(false)
  end

  it 'treats optional pieces as unconditional but keeps later requirements' do
    expect(RP.literal_requirement(/(?:foo)?bar/)).to eq(Contains.new('bar'))
    expect(RP.literal_requirement(/foo|/)).to eq(Any.new)
  end

  it 'uses positive assertions but does not infer requirements from negative assertions' do
    expect(condition_tree(RP.literal_requirement(/(?=foo)bar/))).to eq(
      [:and, [[:contains, 'foo'], [:contains, 'bar']]]
    )
    expect(condition_tree(RP.literal_requirement(/(?!foo)bar/))).to eq([:contains, 'bar'])
    expect(condition_tree(RP.literal_requirement(/(?<=foo)bar/))).to eq(
      [:and, [[:contains, 'foo'], [:contains, 'bar']]]
    )
    expect(condition_tree(RP.literal_requirement(/(?<!foo)bar/))).to eq([:contains, 'bar'])
  end

  it 'combines conditional branches with OR' do
    condition = RP.literal_requirement(/(a)(?(1)b|c)d/)

    expect(condition_tree(condition)).to eq(
      [:and, [
        [:contains, 'a'],
        [:or, [[:contains, 'b'], [:contains, 'c']]],
        [:contains, 'd'],
      ]]
    )
  end

  it 'honors global and locally switched case-insensitive matching' do
    expect(RP.literal_requirement(/(?i:foo)bar/)).to eq(Contains.new('foo', casefold: true).and(Contains.new('bar')))
    expect(RP.literal_requirement('foo', options: Regexp::IGNORECASE).match?('FOO')).to eq(true)
    expect(RP.literal_requirement(/(?i)foo(?-i:bar)/)).not_to match('foo BAR')
    expect(RP.literal_requirement(/\u00df/i).match?('SS')).to eq(true)
  end

  it 'derives finite character sets and falls back for negated or ranged sets' do
    expect(condition_tree(RP.literal_requirement(/[abc]x/))).to eq(
      [:and, [
        [:or, [[:contains, 'a'], [:contains, 'b'], [:contains, 'c']]],
        [:contains, 'x'],
      ]]
    )
    expect(RP.literal_requirement(/[^abc]x/)).to eq(Contains.new('x'))
    expect(RP.literal_requirement(/[a-c]x/)).to eq(Contains.new('x'))
  end

  it 'decodes escape sequences instead of using source text' do
    expect(RP.literal_requirement(/\x62/)).to eq(Contains.new('b'))
    expect(RP.literal_requirement(/a\nb/)).to eq(Contains.new("a\nb"))
    expect(RP.literal_requirement(/\u{62 63}/)).to eq(Contains.new('bc'))
  end

  it 'falls back when syntax is too variable to analyze' do
    expect(RP.literal_requirement(/\d+/)).to eq(Any.new)
    expect(RP.literal_requirement(/\p{ascii}/)).to eq(Any.new)
    expect(RP.literal_requirement(/(?~x)y/)).to eq(Contains.new('y'))
    expect(Any.new.match?('anything')).to eq(true)
  end

  it 'supports UTF-8 and ASCII-8BIT literal encodings' do
    expect(RP.literal_requirement(/\u00e9x/).match?('éx')).to eq(true)
    expect(RP.literal_requirement(/\u00e9x/).match?([0xC3, 0xA9].pack('C*'))).to eq(false)

    binary_requirement = RP.literal_requirement('a\xff', options: Regexp::NOENCODING)
    expect(binary_requirement.match?("a\xff".b)).to eq(true)
    expect(binary_requirement.match?('aé')).to eq(false)
    expect(RP.literal_requirement(/(?u:\u00e9)x/).match?('éx')).to eq(true)
  end

  it 'accepts an already parsed expression tree' do
    root = RP.parse(/foo(?:bar|baz)/)

    expect(RP.literal_requirement(root)).to eq(
      Contains.new('foo').and(Contains.new('bar').or(Contains.new('baz')))
    )
  end

  it 'never rejects a matching string over exhaustive short inputs' do
    patterns = [
      /foo(?:bar|baz)/, /foo|bar/, /a?b/, /(?:x)?y/, /(?!x)foo/,
      /(?=foo)bar/, /(?<=f)oo/, /(?<!f)oo/, /(?i:foo)bar/,
      /[abc]x/, /[^abc]x/, /a\n\tb/, /\x62c/, /[\x78]y/,
      /(a)(?(1)b|c)d/, /a{0}b/, /foo|/, /(foo|bar)?baz/,
    ]
    alphabet = %w[f o b a r z x y A B 0].push("\n", ' ')
    strings = (0..3).flat_map do |length|
      alphabet.repeated_permutation(length).map(&:join)
    end

    false_negative = patterns.any? do |regexp|
      condition = RP.literal_requirement(regexp)
      strings.any? { |string| regexp.match?(string) && !condition.match?(string) }
    end

    expect(false_negative).to eq(false)
  end

  it 'rejects unrelated inputs instead of always passing' do
    alphabet = %w[f o b a r z x y A B 0].push("\n", ' ')
    strings = (0..3).flat_map do |length|
      alphabet.repeated_permutation(length).map(&:join)
    end
    condition = RP.literal_requirement(/foo(?:bar|baz)/)

    expect(strings.count { |string| !condition.match?(string) }).to be > (strings.length * 0.75)
  end
end
