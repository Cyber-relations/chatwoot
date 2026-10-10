# frozen_string_literal: true

require 'digest'
require 'find'
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

# spec_files と overlay/app/spec 配下の *_spec.rb をディスクで突き合わせ、未登録・欠落を fail-closed に
# する(未登録の spec は gate の rspec に渡らず、結果と manifest の照合だけでは見逃すため)。
# "spec_inventory" の宣言が無ければ全件とみなす("complete" は全件の明示)。部分 manifest は subset を
# 宣言する("subset" は確認期限の固定RSpecのように結果との照合だけを行う)。それ以外の値は FAIL。
# 基準ディレクトリは manifest の置き場所 <root>/tests/ から <root>/overlay/app/spec と導くので、
# gate の呼び方(RESULT MANIFEST)は変えない。
SPEC_INVENTORY_COMPLETE = 'complete'
SPEC_INVENTORY_SUBSET = 'subset'
SPEC_ROOT_COMPONENTS = %w[overlay overlay/app overlay/app/spec].freeze
LOG_SAFE_SPEC_PATH = %r{\A[A-Za-z0-9_./-]+\z}

def log_safe_path(file)
  file.valid_encoding? && LOG_SAFE_SPEC_PATH.match?(file) ? file : file.dump
end

def rspec_fail!(reason, path: nil, files: nil)
  fields = ['TOYBACO_CHATWOOT_RSPEC=FAIL', "reason=#{reason}"]
  fields << "path=#{path}" if path
  fields << "files=#{files.sort.map { |file| log_safe_path(file) }.join(',')}" if files
  abort fields.join(' ')
end

def spec_root_for!(manifest_path)
  tests_dir = File.dirname(File.realpath(manifest_path))
  rspec_fail!('spec_root_unavailable', path: 'tests') unless File.basename(tests_dir) == 'tests'
  root = File.dirname(tests_dir)
  SPEC_ROOT_COMPONENTS.each do |relative|
    absolute = File.join(root, relative)
    rspec_fail!('spec_root_unavailable', path: relative) if File.symlink?(absolute) || !File.directory?(absolute)
  end
  File.join(root, SPEC_ROOT_COMPONENTS.last)
end

def spec_files_on_disk!(spec_root)
  app_root = File.dirname(spec_root)
  found = []
  Find.find(spec_root, ignore_error: false) do |path|
    stat = File.lstat(path)
    next if stat.directory?

    relative = path.delete_prefix("#{app_root}/")
    rspec_fail!('unsafe_spec_path', files: [relative]) unless stat.file?
    found << relative if relative.end_with?('_spec.rb')
  end
  found.sort
end

def verify_spec_inventory!(manifest, manifest_path)
  declared = manifest.fetch('spec_inventory', SPEC_INVENTORY_COMPLETE)
  return nil if declared == SPEC_INVENTORY_SUBSET

  registered = manifest['spec_files']
  rspec_fail!('invalid_spec_inventory') unless declared == SPEC_INVENTORY_COMPLETE &&
                                                registered.is_a?(Array) && registered.all? { |file| file.is_a?(String) }
  on_disk = begin
    spec_files_on_disk!(spec_root_for!(manifest_path))
  rescue SystemCallError
    rspec_fail!('spec_root_unavailable', path: SPEC_ROOT_COMPONENTS.last)
  end
  unregistered = on_disk - registered
  rspec_fail!('unregistered_spec', files: unregistered) unless unregistered.empty?
  missing = registered.uniq - on_disk
  rspec_fail!('missing_spec', files: missing) unless missing.empty?
  on_disk.length
end

inventory_spec_count = verify_spec_inventory!(manifest, manifest_path)

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

puts "TOYBACO_CHATWOOT_RSPEC_INVENTORY=PASS specs=#{inventory_spec_count}" if inventory_spec_count
puts "TOYBACO_CHATWOOT_RSPEC=PASS examples=#{example_count} specs=#{actual_specs.length} hash=#{actual_hash}"
