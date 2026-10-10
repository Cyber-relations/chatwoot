# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# verify_chatwoot_rspec_result.rb をサブプロセスで走らせる自己テスト(素の Ruby、Rails なし)。
# gate の quality control 契約で、control snapshot とリポジトリ実体の両方から走る。
# 一時ディレクトリに最小の tests/ と overlay/app/spec と RSpec JSON を作り、spec 名簿の検査
# (宣言なしと "complete" は全件として fail-closed、"subset" は検査なし、それ以外は FAIL)と、
# 既存の件数・hash・spec 名簿の照合が壊れていないことを確かめる。
# spec 名・説明はすべて合成値で、実在の利用者情報や秘密は使わない。
class VerifyChatwootRspecResultTest < Minitest::Test
  REPO_ROOT = File.expand_path('..', __dir__)
  VERIFIER = File.join(REPO_ROOT, 'tests/verify_chatwoot_rspec_result.rb')
  FULL_MANIFEST = 'tests/chatwoot-rspec-manifest.json'
  CONFIRMATION_MANIFEST = 'tests/chatwoot-confirmation-rspec-manifest.json'
  RESULT_KEYS = %w[examples summary summary_line version].freeze
  SUMMARY_KEYS = %w[duration errors_outside_of_examples_count example_count failure_count pending_count].freeze
  EXAMPLE_KEYS = %w[description file_path full_description id line_number pending_message run_time status].freeze
  # 登録する合成 spec ごとの例の数(未登録側の合成 spec はファイルを置くだけで例を作らない)。
  FIXTURE_SPECS = {
    'spec/lib/toybaco/alpha_spec.rb' => 2,
    'spec/models/beta_spec.rb' => 1
  }.freeze
  REGISTERED = %w[spec/lib/toybaco/alpha_spec.rb spec/models/beta_spec.rb].freeze
  # 全件として検査される宣言(:absent はキー自体が無い manifest)。
  FULL_DECLARATIONS = [:absent, 'complete'].freeze

  def setup
    @root = Dir.mktmpdir('toybaco-rspec-verifier-')
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def write_spec(relative)
    path = File.join(@root, 'overlay/app', relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "# frozen_string_literal: true\n")
  end

  def examples_for(specs)
    specs.sort.flat_map do |file|
      Array.new(FIXTURE_SPECS.fetch(file)) do |index|
        {
          'id' => "./#{file}[1:#{index + 1}]",
          'description' => "synthetic example #{index + 1}",
          'full_description' => "Synthetic #{File.basename(file, '.rb')} example #{index + 1}",
          'status' => 'passed',
          'file_path' => "./#{file}",
          'line_number' => index + 3,
          'run_time' => 0.001,
          'pending_message' => nil
        }
      end
    end
  end

  # verifier と同じ正規形(id / './' を除いた file_path / line_number / full_description を id 順)の SHA-256。
  def canonical_hash(examples)
    canonical = examples.map do |example|
      {
        'id' => example.fetch('id'),
        'file_path' => example.fetch('file_path').delete_prefix('./'),
        'line_number' => example.fetch('line_number'),
        'full_description' => example.fetch('full_description')
      }
    end
    Digest::SHA256.hexdigest(JSON.generate(canonical.sort_by { |example| example.fetch('id') }))
  end

  def write_result(examples)
    result = {
      'version' => '3.13.0',
      'examples' => examples,
      'summary' => {
        'duration' => 0.5, 'example_count' => examples.length, 'failure_count' => 0,
        'pending_count' => 0, 'errors_outside_of_examples_count' => 0
      },
      'summary_line' => "#{examples.length} examples, 0 failures"
    }
    path = File.join(@root, 'results/rspec.json')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(result))
    path
  end

  def write_manifest(spec_files, examples, inventory: :absent, overrides: {}, location: FULL_MANIFEST)
    manifest = {
      'schema' => 'toybaco-chatwoot-rspec-v1',
      'rspec_version' => '3.13.0',
      'result_keys' => RESULT_KEYS,
      'summary_keys' => SUMMARY_KEYS,
      'example_keys' => EXAMPLE_KEYS,
      'example_count' => examples.length,
      'examples_sha256' => canonical_hash(examples)
    }
    manifest['spec_inventory'] = inventory unless inventory == :absent
    manifest['spec_files'] = spec_files.sort
    path = File.join(@root, location)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(manifest.merge(overrides)) + "\n")
    path
  end

  def run_verifier(result_path, manifest_path)
    Open3.capture3(RbConfig.ruby, VERIFIER, result_path, manifest_path)
  end

  def assert_fails_with(line, result_path, manifest_path)
    stdout, stderr, status = run_verifier(result_path, manifest_path)
    refute status.success?, "verifier unexpectedly passed: #{stdout}"
    assert_includes stderr.lines.map(&:chomp), line
    # 名簿検査の FAIL は 1 行だけ。既存の照合で落ちるときは名簿検査を通過していて FAIL 行は出ない。
    fail_lines = line.start_with?('TOYBACO_CHATWOOT_RSPEC=FAIL') ? 1 : 0
    assert_equal fail_lines, stderr.lines.count { |entry| entry.include?('TOYBACO_CHATWOOT_RSPEC=FAIL') }
    refute_includes stdout, 'PASS'
  end

  def registered_fixture
    REGISTERED.each { |spec| write_spec(spec) }
    write_spec('spec/support/helper.rb')
    examples = examples_for(REGISTERED)
    [write_result(examples), examples]
  end

  # 実ツリーの spec を verifier と同じ方式(Find の ignore_error: false + lstat)で集める。隠しパスも
  # 走査し、ディレクトリ以外で通常ファイルでないもの(symlink・特殊ファイル)は辿らずに flunk する。
  def spec_files_under(app_root)
    found = []
    Find.find(File.join(app_root, 'spec'), ignore_error: false) do |path|
      stat = File.lstat(path)
      next if stat.directory?

      relative = path.delete_prefix("#{app_root}/")
      flunk "spec tree must hold only regular files and directories: #{relative}" unless stat.file?
      found << relative if relative.end_with?('_spec.rb')
    end
    found.sort
  end

  # (b) 宣言なし(と "complete")で全件登録済みなら、名簿行つきで従来どおり PASS(補助ファイルは対象外)。
  def test_passes_when_every_spec_on_disk_is_registered
    result_path, examples = registered_fixture
    FULL_DECLARATIONS.each do |inventory|
      stdout, stderr, status = run_verifier(result_path, write_manifest(REGISTERED, examples, inventory: inventory))
      assert status.success?, "#{inventory.inspect}: #{stderr}"
      assert_equal [
        'TOYBACO_CHATWOOT_RSPEC_INVENTORY=PASS specs=2',
        "TOYBACO_CHATWOOT_RSPEC=PASS examples=3 specs=2 hash=#{canonical_hash(examples)}"
      ], stdout.lines.map(&:chomp)
    end
  end

  # (a) 宣言なし(と "complete")で未登録 spec が 1 つあると、結果と manifest が整合していても FAIL。
  def test_fails_closed_on_one_unregistered_spec
    result_path, examples = registered_fixture
    write_spec('spec/requests/toybaco/gamma_spec.rb')
    FULL_DECLARATIONS.each do |inventory|
      assert_fails_with 'TOYBACO_CHATWOOT_RSPEC=FAIL reason=unregistered_spec files=spec/requests/toybaco/gamma_spec.rb',
                        result_path, write_manifest(REGISTERED, examples, inventory: inventory)
    end
  end

  def test_lists_every_unregistered_spec_in_bytewise_order
    result_path, examples = registered_fixture
    write_spec('spec/requests/toybaco/gamma_spec.rb')
    write_spec('spec/lib/toybaco/delta_spec.rb')
    assert_fails_with 'TOYBACO_CHATWOOT_RSPEC=FAIL reason=unregistered_spec ' \
                      'files=spec/lib/toybaco/delta_spec.rb,spec/requests/toybaco/gamma_spec.rb',
                      result_path, write_manifest(REGISTERED, examples)
  end

  # 逆向き: manifest にあるがディスクに無い spec も FAIL。
  def test_fails_closed_on_registered_spec_missing_from_disk
    write_spec('spec/lib/toybaco/alpha_spec.rb')
    examples = examples_for(REGISTERED)
    result_path = write_result(examples)
    FULL_DECLARATIONS.each do |inventory|
      assert_fails_with 'TOYBACO_CHATWOOT_RSPEC=FAIL reason=missing_spec files=spec/models/beta_spec.rb',
                        result_path, write_manifest(REGISTERED, examples, inventory: inventory)
    end
  end

  # (c) "subset" を宣言した部分 manifest(確認期限の固定 RSpec)は名簿検査をせず、名簿行なしで PASS。
  def test_subset_manifest_skips_inventory_check
    registered_fixture
    write_spec('spec/requests/toybaco/gamma_spec.rb')
    subset = ['spec/models/beta_spec.rb']
    examples = examples_for(subset)
    manifest = write_manifest(subset, examples, inventory: 'subset', location: CONFIRMATION_MANIFEST)
    stdout, stderr, status = run_verifier(write_result(examples), manifest)
    assert status.success?, stderr
    assert_equal ["TOYBACO_CHATWOOT_RSPEC=PASS examples=1 specs=1 hash=#{canonical_hash(examples)}"],
                 stdout.lines.map(&:chomp)
  end

  # "subset" が外すのは名簿検査だけで、既存の照合は残る。
  def test_subset_manifest_keeps_existing_checks
    registered_fixture
    subset = ['spec/models/beta_spec.rb']
    examples = examples_for(subset)
    manifest = write_manifest(subset, examples, inventory: 'subset', overrides: { 'example_count' => 2 },
                                                location: CONFIRMATION_MANIFEST)
    assert_fails_with 'RSpec example count mismatch: 1', write_result(examples), manifest
  end

  # (d) 宣言値は "complete" / "subset" だけ。null・真偽値・数値・配列・表記ゆれは FAIL。
  def test_rejects_unknown_inventory_declaration
    result_path, examples = registered_fixture
    ['all', 'Complete', 'SUBSET', 'subset ', '', true, false, nil, 1, ['subset'], { 'mode' => 'subset' }].each do |value|
      assert_fails_with 'TOYBACO_CHATWOOT_RSPEC=FAIL reason=invalid_spec_inventory',
                        result_path, write_manifest(REGISTERED, examples, inventory: value)
    end
  end

  def test_rejects_inventory_without_string_spec_list
    result_path, examples = registered_fixture
    FULL_DECLARATIONS.each do |inventory|
      [nil, 'spec/models/beta_spec.rb', ['spec/models/beta_spec.rb', 1]].each do |value|
        manifest = write_manifest(REGISTERED, examples, inventory: inventory, overrides: { 'spec_files' => value })
        assert_fails_with 'TOYBACO_CHATWOOT_RSPEC=FAIL reason=invalid_spec_inventory', result_path, manifest
      end
    end
  end

  def test_fails_closed_when_spec_root_is_missing
    examples = examples_for(REGISTERED)
    assert_fails_with 'TOYBACO_CHATWOOT_RSPEC=FAIL reason=spec_root_unavailable path=overlay',
                      write_result(examples), write_manifest(REGISTERED, examples)
    FileUtils.mkdir_p(File.join(@root, 'overlay/app'))
    assert_fails_with 'TOYBACO_CHATWOOT_RSPEC=FAIL reason=spec_root_unavailable path=overlay/app/spec',
                      write_result(examples), write_manifest(REGISTERED, examples)
  end

  def test_fails_closed_when_manifest_is_outside_tests_directory
    result_path, examples = registered_fixture
    manifest = write_manifest(REGISTERED, examples, location: 'contract/chatwoot-rspec-manifest.json')
    assert_fails_with 'TOYBACO_CHATWOOT_RSPEC=FAIL reason=spec_root_unavailable path=tests', result_path, manifest
  end

  def test_rejects_symlink_inside_spec_tree
    result_path, examples = registered_fixture
    File.symlink(File.join(@root, 'overlay/app/spec/models/beta_spec.rb'),
                 File.join(@root, 'overlay/app/spec/models/linked_spec.rb'))
    assert_fails_with 'TOYBACO_CHATWOOT_RSPEC=FAIL reason=unsafe_spec_path files=spec/models/linked_spec.rb',
                      result_path, write_manifest(REGISTERED, examples)
  end

  def test_rejects_symlinked_spec_root
    result_path, examples = registered_fixture
    FileUtils.mv(File.join(@root, 'overlay/app/spec'), File.join(@root, 'elsewhere'))
    File.symlink(File.join(@root, 'elsewhere'), File.join(@root, 'overlay/app/spec'))
    assert_fails_with 'TOYBACO_CHATWOOT_RSPEC=FAIL reason=spec_root_unavailable path=overlay/app/spec',
                      result_path, write_manifest(REGISTERED, examples)
  end

  # 隠しディレクトリの spec も名簿の対象(Dir.glob の既定と違い、Find は隠しパスも走査する)。
  def test_fails_closed_on_unregistered_spec_in_hidden_directory
    result_path, examples = registered_fixture
    write_spec('spec/.hidden/zeta_spec.rb')
    assert_fails_with 'TOYBACO_CHATWOOT_RSPEC=FAIL reason=unregistered_spec files=spec/.hidden/zeta_spec.rb',
                      result_path, write_manifest(REGISTERED, examples)
  end

  # spec ツリー内の symlink ディレクトリは辿らず unsafe_spec_path で FAIL(リンク先の spec が名簿から隠れない)。
  def test_rejects_symlinked_directory_inside_spec_tree
    result_path, examples = registered_fixture
    elsewhere = File.join(@root, 'elsewhere')
    FileUtils.mkdir_p(elsewhere)
    File.write(File.join(elsewhere, 'omega_spec.rb'), "# frozen_string_literal: true\n")
    File.symlink(elsewhere, File.join(@root, 'overlay/app/spec/models/linked'))
    assert_fails_with 'TOYBACO_CHATWOOT_RSPEC=FAIL reason=unsafe_spec_path files=spec/models/linked',
                      result_path, write_manifest(REGISTERED, examples)
  end

  # 読めないディレクトリを黙って飛ばさない(Find の既定の ignore_error に頼らない)。
  # 権限を無視できる実行者では読めてしまうため、そのときは未登録 spec として FAIL することを確かめる。
  def test_fails_closed_when_spec_tree_is_unreadable
    result_path, examples = registered_fixture
    write_spec('spec/hidden/zeta_spec.rb')
    hidden = File.join(@root, 'overlay/app/spec/hidden')
    File.chmod(0o000, hidden)
    listable = begin
      Dir.children(hidden)
      true
    rescue SystemCallError
      false
    end
    expected = if listable
                 'TOYBACO_CHATWOOT_RSPEC=FAIL reason=unregistered_spec files=spec/hidden/zeta_spec.rb'
               else
                 'TOYBACO_CHATWOOT_RSPEC=FAIL reason=spec_root_unavailable path=overlay/app/spec'
               end
    assert_fails_with expected, result_path, write_manifest(REGISTERED, examples)
  ensure
    File.chmod(0o755, hidden) if hidden && File.exist?(hidden)
  end

  # 既存の照合: 件数の不一致。
  def test_existing_example_count_check_still_fails
    result_path, examples = registered_fixture
    manifest = write_manifest(REGISTERED, examples, overrides: { 'example_count' => 4 })
    assert_fails_with 'RSpec example count mismatch: 3', result_path, manifest
  end

  # 既存の照合: hash の不一致。
  def test_existing_hash_check_still_fails
    result_path, examples = registered_fixture
    manifest = write_manifest(REGISTERED, examples, overrides: { 'examples_sha256' => '0' * 64 })
    assert_fails_with "RSpec exact example manifest hash mismatch: #{canonical_hash(examples)}", result_path, manifest
  end

  # 既存の照合: 登録済み spec の例が結果に無い(件数と hash は結果に合わせても FAIL)。
  def test_existing_spec_list_check_still_fails
    registered_fixture
    executed = examples_for(['spec/lib/toybaco/alpha_spec.rb'])
    manifest = write_manifest(REGISTERED, executed)
    assert_fails_with 'RSpec exact spec list mismatch: ["spec/lib/toybaco/alpha_spec.rb"]',
                      write_result(executed), manifest
  end

  # (e) 実リポジトリの manifest 2 つ: 全件は "complete" でディスクの spec(隠しパスを含め verifier と同じ
  # 方式で走査)と bytewise sort 済みで一致し、確認期限の固定 RSpec は "subset" で、載せた spec がディスクに
  # あり全件 manifest にも登録されている。
  def test_repository_manifests_declare_their_inventory
    full = JSON.parse(File.read(File.join(REPO_ROOT, FULL_MANIFEST)))
    assert_equal 'complete', full['spec_inventory']
    full_specs = full.fetch('spec_files')
    assert_equal full_specs.uniq.sort, full_specs
    on_disk = spec_files_under(File.join(REPO_ROOT, 'overlay/app'))
    assert_equal on_disk, full_specs

    confirmation = JSON.parse(File.read(File.join(REPO_ROOT, CONFIRMATION_MANIFEST)))
    assert_equal 'subset', confirmation['spec_inventory']
    confirmation_specs = confirmation.fetch('spec_files')
    refute_empty confirmation_specs
    assert_equal [], confirmation_specs - on_disk
    assert_equal [], confirmation_specs - full_specs
  end
end
