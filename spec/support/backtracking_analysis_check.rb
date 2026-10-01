# frozen_string_literal: true

require 'regexp_parser'

analyzer = Regexp::Parser::BacktrackingStaticAnalyzer
interpreter = Regexp::Parser::BacktrackingInterpreter

def assert(condition, message)
  raise message unless condition
end

def degree(finding)
  first = finding.measurements.first
  last = finding.measurements.last
  Math.log(last[:steps].to_f / first[:steps]) /
    Math.log(last[:size].to_f / first[:size])
end

nested = analyzer.analyze('\A(?:a*)*!', sizes: [6, 8, 10], step_limit: 1_000_000)
assert(nested.status == :unsafe, 'expected nested quantification to be unsafe')
finding = nested.findings.first
assert(finding.severity == :exponential, 'expected exponential nested quantification')
assert(finding.prefix == '', 'expected empty prefix')
assert(finding.repeat == 'a', 'expected repeat a')
assert(!finding.failing_suffix.empty?, 'expected a failing suffix')
assert(finding.ast_path == [1], 'expected path [1]')
assert(finding.starts_at == 2, 'expected AST position 2')
assert(finding.measurements.length == 3, 'expected three measurements')
ratio = finding.measurements.last[:steps].to_f / finding.measurements.first[:steps]
assert(ratio > 3, "expected exponential ratio, got #{ratio}")

ordered = analyzer.analyze('\A(?:a|aa)*!', sizes: [6, 8, 10], step_limit: 1_000_000)
assert(ordered.status == :unsafe, 'expected ordered alternation to be unsafe')
assert(ordered.findings.first.severity == :exponential, 'expected exponential alternation')

quadratic = analyzer.analyze('\Aa*a*!', sizes: [8, 12, 16], step_limit: 1_000_000)
assert(quadratic.status == :unsafe, 'expected adjacent quantifiers to be unsafe')
quadratic_finding = quadratic.findings.first
assert(quadratic_finding.severity == :polynomial, 'expected polynomial growth')
assert((1.6..2.4).cover?(degree(quadratic_finding)),
       "expected quadratic degree, got #{degree(quadratic_finding)}")
assert(quadratic_finding.locations.map { |location| location[:ast_path] } == [[1], [2]],
       'expected both ambiguous quantifier locations')

unanchored = analyzer.analyze('a*!', sizes: [8, 12, 16], step_limit: 1_000_000)
assert(unanchored.status == :unsafe, 'expected unanchored search to add a polynomial degree')
assert(unanchored.findings.first.severity == :polynomial, 'expected unanchored polynomial')

assert(analyzer.analyze('\Aa*!').status == :safe, 'single anchored quantifier must be safe')
assert(analyzer.analyze('\A(?:a*){1}!').status == :safe,
       'single fixed repetition must be safe')
finite = analyzer.analyze('\A(?:a*){2}!', sizes: [8, 12, 16], step_limit: 1_000_000)
assert(finite.status == :unsafe && finite.findings.first.severity == :polynomial,
       'bounded nested quantifiers must be polynomial')
assert(analyzer.analyze('\Aa*+!').status == :safe, 'possessive quantifier must be safe')
assert(analyzer.analyze('\A(?>a*)*!').status == :safe, 'atomic outer repetition must be safe')
assert(analyzer.analyze('\A(?:a|aa)*+!').status == :safe, 'possessive alternation must be safe')
assert(analyzer.analyze('\A(?:a|b)*!').status == :safe, 'disjoint alternatives must be safe')
assert(analyzer.analyze('\A(?:a|a)*!', sizes: [6, 8, 10]).status == :unsafe,
       'duplicate ordered alternatives must be detected')
assert(analyzer.analyze('\A[[:alpha:]]*[[:alpha:]]*!',
                        sizes: [8, 12, 16]).status == :unsafe,
       'POSIX character class overlap must be detected')

lazy = analyzer.analyze('\A(?:a*?)*!', sizes: [6, 8, 10], step_limit: 1_000_000)
assert(lazy.status == :unsafe && lazy.findings.first.severity == :exponential,
       'lazy nested quantification must remain vulnerable')

internal = analyzer.analyze('\A(?>(?:a*)*!)z', sizes: [6, 8, 10], step_limit: 1_000_000)
assert(internal.status == :unsafe && internal.findings.first.ast_path == [1, 0],
       'atomic internals must be analyzed with an internal failure')

%w[(a)\1 (a)\g<1> (a)(?(1)b|c) (a)(?!b) (?~abc)].each do |pattern|
  result = analyzer.analyze(pattern)
  assert(result.status == :unknown, "expected unknown for #{pattern}")
  assert(result.findings.first.severity == :unknown, "expected unknown finding for #{pattern}")
end

steps = [6, 8, 10].map do |size|
  root = Regexp::Parser.parse('\A(?:a*)*!')
  interpreter.new(step_limit: 1_000_000).failure_steps(root, 'a' * size + 'x')
end
assert(steps == [3644, 32804, 295244], "expected counted exponential steps, got #{steps.inspect}")

atomic_root = Regexp::Parser.parse('\A(?>a*)*!')
atomic_steps = [2, 4, 8].map do |size|
  interpreter.new.failure_steps(atomic_root, 'a' * size + 'x')
end
assert(atomic_steps == [8, 10, 14], "expected linear atomic steps, got #{atomic_steps.inspect}")

possessive_root = Regexp::Parser.parse('\Aa*+!')
possessive_steps = [2, 4, 8].map do |size|
  interpreter.new.failure_steps(possessive_root, 'a' * size + 'x')
end
assert(possessive_steps == [4, 6, 10],
       "expected linear possessive steps, got #{possessive_steps.inspect}")

puts 'backtracking analysis checks passed'
