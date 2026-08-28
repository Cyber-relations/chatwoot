# frozen_string_literal: true

require 'digest'
require 'json'

result_path, manifest_path = ARGV
abort 'usage: verify_chatwoot_rspec_result.rb RESULT MANIFEST' unless result_path && manifest_path

result = JSON.parse(File.read(result_path))
manifest = JSON.parse(File.read(manifest_path))
abort 'unsupported RSpec manifest schema' unless manifest['schema'] == 'toybaco-chatwoot-rspec-v1'

def exact_keys!(object, expected, label)
  actual = object.keys.sort
  wanted = expected.sort
  abort "#{label} JSON schema mismatch: actual=#{actual.inspect} expected=#{wanted.inspect}" unless actual == wanted
end

exact_keys!(result, manifest.fetch('result_keys'), 'RSpec result')
abort "RSpec version mismatch: #{result['version']}" unless result.fetch('version') == manifest.fetch('rspec_version')

summary = result.fetch('summary')
exact_keys!(summary, manifest.fetch('summary_keys'), 'RSpec summary')
example_count = Integer(summary.fetch('example_count'))
failure_count = Integer(summary.fetch('failure_count'))
pending_count = Integer(summary.fetch('pending_count'))
outside_errors = Integer(summary.fetch('errors_outside_of_examples_count', 0))
duration = Float(summary.fetch('duration'))
abort 'RSpec duration must be finite and non-negative' unless duration.finite? && duration >= 0

examples = result.fetch('examples')
abort 'RSpec examples must be an array' unless examples.is_a?(Array)
abort "RSpec summary/example length mismatch: #{example_count}/#{examples.length}" unless example_count == examples.length
abort "RSpec example count mismatch: #{example_count}" unless example_count == Integer(manifest.fetch('example_count'))
abort "RSpec failures: #{failure_count}" unless failure_count.zero?
abort "RSpec pending/skips: #{pending_count}" unless pending_count.zero?
abort "RSpec errors outside examples: #{outside_errors}" unless outside_errors.zero?

canonical_examples = examples.map do |example|
  exact_keys!(example, manifest.fetch('example_keys'), "RSpec example #{example['id']}")
  abort "RSpec non-passed example: #{example['id']}" unless example.fetch('status') == 'passed'
  run_time = Float(example.fetch('run_time'))
  abort "RSpec run_time must be finite and non-negative: #{example['id']}" unless run_time.finite? && run_time >= 0

  {
    'id' => example.fetch('id'),
    'file_path' => example.fetch('file_path').delete_prefix('./'),
    'line_number' => Integer(example.fetch('line_number')),
    'full_description' => example.fetch('full_description')
  }
end

ids = canonical_examples.map { |example| example.fetch('id') }
abort 'RSpec example ids must be unique' unless ids.uniq.length == ids.length
canonical_examples.sort_by! { |example| example.fetch('id') }
canonical_json = JSON.generate(canonical_examples)
actual_hash = Digest::SHA256.hexdigest(canonical_json)
abort "RSpec exact example manifest hash mismatch: #{actual_hash}" unless
  actual_hash == manifest.fetch('examples_sha256')

actual_specs = canonical_examples.map { |example| example.fetch('file_path') }.uniq.sort
expected_specs = manifest.fetch('spec_files').sort
abort "RSpec exact spec list mismatch: #{actual_specs.inspect}" unless actual_specs == expected_specs

puts "TOYBACO_CHATWOOT_RSPEC=PASS examples=#{example_count} specs=#{actual_specs.length} hash=#{actual_hash}"
