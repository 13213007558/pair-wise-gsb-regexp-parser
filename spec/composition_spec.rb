# frozen_string_literal: true

require 'spec_helper'

RSpec.describe('Composition') do
  it 'connects fragments and rewrites numbered references' do
    first = RP.parse('(a)\\1\\k<-1>')
    second = RP.parse('(b)(c)\\g<2>\\g<-1>')

    root = Regexp::Parser.concat(
      Regexp::Parser.fragment(first, id: 'first'),
      Regexp::Parser.fragment(second, id: 'second')
    )

    expect(root.to_s).to eq '(?:(a)\\1\\k<1>)(?:(b)(c)\\g<3>\\g<3>)'
    expect(root.to_re.match('aaabccc').captures).to eq %w[a b c]
  end

  it 'renames conflicting named captures and restores their old names' do
    left = RP.parse('(?<value>a)\\k<value>')
    right = RP.parse('(?<value>b)\\k<value>')

    root = Regexp::Parser.concat(
      Regexp::Parser.fragment(left, id: 'left'),
      Regexp::Parser.fragment(right, id: 'right'),
      on_name_conflict: :rename
    )
    match = root.to_re.match('aabb')

    expect(root.to_s).to include('c0_0_value').and include('c1_0_value')
    restored = root.composition_capture_map.restore(match)
    expect(restored[['left', 'value', [0, 0]]]).to eq 'a'
    expect(restored[['right', 'value', [1, 0]]]).to eq 'b'
  end

  it 'uses the same fragment in two branches inside another named fragment' do
    shared = Regexp::Parser.fragment(
      RP.parse('(?<part>p\\k<part>?)'), id: 'shared'
    )
    branches = Regexp::Parser.alternate(shared, shared,
                                       on_name_conflict: :rename)
    outer = Regexp::Parser.fragment(RP.parse('(?<outer>outer)'), id: 'outer')

    root = Regexp::Parser.concat(
      outer,
      Regexp::Parser.fragment(branches, id: 'branches'),
      on_name_conflict: :keep
    )
    match = root.to_re.match('outerpp')

    expect(match.named_captures.fetch('outer')).to eq 'outer'
    branch_captures = root.composition_capture_map['shared']
    values = branch_captures.map { |entry| entry.value(match) }.compact
    expect(values).to eq ['p']
  end

  it 'repeats a fragment with a quantifier' do
    fragment = Regexp::Parser.fragment(RP.parse('(a)'), id: 'fragment')
    root = Regexp::Parser.repeat(fragment, '{2,3}')

    expect(root.to_s).to eq '(?:(?:(a))){2,3}'
    expect(root.to_re.match('aa')[0]).to eq 'aa'
  end

  it 'preserves local option scopes' do
    first = RP.parse(/A/i)
    second = RP.parse('B')
    root = Regexp::Parser.concat(
      Regexp::Parser.fragment(first, id: 'first'),
      Regexp::Parser.fragment(second, id: 'second')
    )

    expect(root.to_s).to eq '(?i-mx:(?:A))(?:B)'
    expect(root.to_re.match('aB')[0]).to eq 'aB'
    expect(root.to_re.match('aX')).to be_nil
  end

  it 'reports an invalid reference with its reference chain' do
    parsed = RP.parse('(a)')
    backreference = Regexp::Expression::Backreference::Number.construct(
      text: '\\2', token: :number
    )
    backreference.instance_variable_set(:@number, 2)
    parsed << backreference

    expect do
      Regexp::Parser.concat(Regexp::Parser.fragment(parsed, id: 'invalid'))
    end.to raise_error(Regexp::Parser::CompositionError, /reference chain: \\2/)
  end
end
