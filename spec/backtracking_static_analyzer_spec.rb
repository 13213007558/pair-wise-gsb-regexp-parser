# frozen_string_literal: true

require 'open3'

RSpec.describe 'backtracking static analyzer' do
  it 'validates diagnoses and counting interpreter growth in an isolated process' do
    command = [
      Gem.ruby, '-Ilib',
      File.expand_path('support/backtracking_analysis_check.rb', __dir__)
    ]
    stdout, stderr, status = Open3.capture3(*command)

    expect(status).to be_success, [stdout, stderr].join("\n")
  end
end
