# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Regexp::Parser::Composition do
  let(:composition) { described_class }

  specify 'concatenates captures and remaps numeric backreferences' do
    result = composition.concat('(a)\1', '(b)\1')

    expect(result.to_s).to eq '(a)\1(b)\2'
    expect(Regexp.new(result.to_s).match('aabb').captures).to eq %w[a b]
  end

  specify 'branches the same fragment and remaps relative subexpression calls' do
    fragment = '(?<word>\w+)\g<word>'
    result = composition.alternate(fragment, fragment, on_name_conflict: :rename)

    expect(result.to_s).to eq(
      '(?<word_1>\w+)\g<word_1>|(?<word_2>\w+)\g<word_2>'
    )

    regexp = Regexp.new(result.to_s)
    expect(regexp.match('aa').named_captures).to eq(
      'word_1' => 'a', 'word_2' => nil
    )
    expect(regexp.match('bb').named_captures).to eq(
      'word_1' => 'b', 'word_2' => nil
    )
  end

  specify 'nests branches in an explicitly named capture and restores old names' do
    fragment = '(?<word>\w+)\k<word>'
    branches = composition.alternate(fragment, fragment, on_name_conflict: :rename)
    result = composition.capture(branches, 'outer', on_name_conflict: :rename)
    match = Regexp.new(result.to_s).match('aa')
    extracted = result.extract(match)

    expect(result.to_s).to eq(
      '(?<outer>(?<word_1>\w+)\k<word_1>|(?<word_2>\w+)\k<word_2>)'
    )
    expect(extracted['word']).to eq ['a', nil]
    expect(match[:outer]).to eq 'aa'
  end

  specify 'repeats a fragment as one subexpression' do
    result = composition.repeat('(a)\1', '?')

    expect(result.to_s).to eq '(?:(a)\1)?'
    expect(Regexp.new(result.to_s).match('aa').captures).to eq ['a']
  end

  specify 'repeats a captureless fragment' do
    result = composition.repeat('a', 3)

    expect(result.to_s).to eq '(?:a){3,3}'
    expect(Regexp.new(result.to_s).match('aaa')).not_to be_nil
  end

  specify 'supports numeric recursion-level references' do
    result = composition.concat('(a)\k<1-0>', '')

    expect(result.to_s).to eq '(a)\k<1+0>'
  end

  specify 'supports named recursion-level references' do
    result = composition.concat('(?<x>a)\k<x-0>', '')

    expect(result.to_s).to eq '(?<x>a)\k<x-0>'
  end

  specify 'remaps conditional references' do
    result = composition.concat('(a)(?(1)b|c)\1', '(d)\1')

    expect(result.to_s).to eq '(a)(?(1)b|c)\1(d)\2'
    expect(Regexp.new(result.to_s).match('abadd').captures).to eq %w[a d]
  end

  specify 'keeps fragment root recursion scoped to that fragment' do
    result = composition.capture('a|b\g<0>', 'outer')
    match = Regexp.new(result.to_s).match('bba')

    expect(match[:outer]).to eq 'bba'
  end

  specify 'can repeat and re-wrap an already composed recursive fragment' do
    recursive = composition.alternate('a|b\g<0>', '')
    result = composition.repeat(recursive, '?')
    match = Regexp.new(result.to_s).match('bba')

    expect(match[1]).to eq 'bba'

    wrapped = composition.capture(
      composition.alternate('(?<w>a)\k<w>', '(?<w>b)\k<w>', on_name_conflict: :rename),
      'outer', on_name_conflict: :rename
    )

    expect(Regexp.new(wrapped.to_s).match('aa')[:outer]).to eq 'aa'
  end

  specify 'isolates top-level option switches' do
    result = composition.concat('(?i)A', 'b')
    regexp = Regexp.new(result.to_s)

    expect(result.to_s).to eq '(?:(?i)A)b'
    expect(regexp.match('Ab')).not_to be_nil
    expect(regexp.match('B')).to be_nil
  end

  specify 'isolates options carried by a Regexp AST' do
    result = composition.concat(Regexp::Parser.parse(/a/i), 'b')
    regexp = Regexp.new(result.to_s)

    expect(result.to_s).to eq '(?i-mx:a)b'
    expect(regexp.match('Ab')).not_to be_nil
    expect(regexp.match('ac')).to be_nil
  end

  specify 'reports name conflicts at construction time' do
    expect { composition.concat('(?<a>a)', '(?<a>b)') }
      .to raise_error(Regexp::Parser::CompositionError, /capture name "a"/)
  end

  specify 'supports keeping duplicate names' do
    result = composition.concat('(?<a>a)', '(?<a>b)', on_name_conflict: :keep)

    expect(result.to_s).to eq '(?<a>a)(?<a>b)'
  end

  specify 'renames all aliases in a fragment that legally used one name twice' do
    fragment = '(?<x>a)|(?<x>b)\k<x>'
    result = composition.alternate(fragment, fragment, on_name_conflict: :rename)

    expect(result.to_s).to eq(
      '(?<x_1>a)|(?<x_1>b)\k<x_1>|(?<x_2>a)|(?<x_2>b)\k<x_2>'
    )
    expect(Regexp.new(result.to_s).match('bb').named_captures).to eq(
      'x_1' => 'b', 'x_2' => nil
    )
  end

  specify 'rejects unknown name conflict policies' do
    expect { composition.concat('a', 'b', on_name_conflict: :nope) }
      .to raise_error(ArgumentError, /on_name_conflict/)
  end

  specify 'reports invalid references when a fragment is constructed' do
    expect { composition.concat('(?<x>a)', '(?<y>b)\k<x>') }
      .to raise_error(Regexp::Parser::ParserError, /Invalid reference x/)
  end
end
