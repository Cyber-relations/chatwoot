# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'

class ChatwootWidgetSessionGateTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  VARIABLE = 'TOYBACO_WIDGET_SESSION_SECURITY_EPOCH'
  EPOCH = "#{VARIABLE}=2000-01-01T00:00:00Z"

  def gate
    File.read(File.join(ROOT, 'bin/toybaco-chatwoot-gate'))
  end

  def function(name)
    gate[/^#{Regexp.escape(name)}\(\) \{\n.*?^\}\n/m] || raise("missing gate function #{name}")
  end

  def test_both_container_environment_builders_pass_a_fixed_epoch
    %w[test_env_args production_env_args].each do |name|
      # Evaluate only the reviewed printf-only function, never the gate entrypoint.
      environment = { 'POSTGRES_TEST_PASSWORD' => 'test-only', 'SYNC_TEST_PASSWORD' => 'test-only',
                      'CHATWOOT_SOURCE_COMMIT' => 'test-revision' }
      output, error, status = Open3.capture3(environment, 'bash', '-s', stdin_data: "#{function(name)}\n#{name}\n")
      assert status.success?, error
      assert_includes output.lines.map(&:chomp).each_slice(2).to_a, ['--env', EPOCH]
    end
  end

  def test_all_gate_rails_boot_paths_receive_those_arguments
    assert_includes function('run_test_container'), 'done < <(test_env_args)'
    %w[run_production_container start_production_service].each do |name|
      assert_includes function(name), 'done < <(production_env_args)'
    end
    # The database preparation/recovery checks override RAILS_ENV=test to production.
    prepare = function('verify_toybaco_database_prepare')
    assert_operator prepare.scan('--env RAILS_ENV=production').size, :>, 0
    assert_equal prepare.scan('--env RAILS_ENV=production').size,
                 prepare.scan(/run_test_container \\\n    --env RAILS_ENV=production/).size
  end

  def test_test_image_supports_production_boots_without_setting_a_shipped_default
    assert_includes File.read(File.join(ROOT, 'tests/chatwoot-test.Dockerfile')), EPOCH
    dockerfile = File.read(File.join(ROOT, 'Dockerfile'))
    refute shipped_epoch_declaration?(dockerfile), 'shipped Dockerfile must not declare an epoch ENV or ARG'
    refute_includes dockerfile, '2000-01-01T00:00:00Z'
    assert_includes dockerfile, 'RAILS_ENV=production SECRET_KEY_BASE=precompile_placeholder'
    assert_includes dockerfile, '/toybaco-overlay/config/initializers/toybaco_widget_session_epoch.rb /app/config/initializers/'
    assert_includes dockerfile, '/toybaco-overlay/lib/toybaco/security/widget_session_security_epoch.rb /app/lib/toybaco/security/'
  end

  def shipped_epoch_declaration?(source)
    source.gsub(/\\\r?\n/, ' ').lines.any? do |line|
      line.match?(/\A\s*(?:ENV|ARG)\s/i) && line.match?(/\b#{VARIABLE}\b/)
    end
  end

  def test_shipped_epoch_check_rejects_env_and_arg_including_legacy_and_continued_syntax
    ["ENV #{EPOCH}\n", "ENV #{VARIABLE} 2000-01-01T00:00:00Z\n",
     "ENV RAILS_ENV=production \\\n    #{EPOCH}\n", "ARG #{EPOCH}\n", "ARG #{VARIABLE}\n"].each do |source|
      assert shipped_epoch_declaration?(source), source
    end
    refute shipped_epoch_declaration?("# ENV #{EPOCH}\nCOPY epoch.rb /app/\n")
  end

  def test_epoch_checks_are_in_the_control_snapshot_and_gate_execution
    %w[chatwoot_widget_session_epoch_test.rb chatwoot_widget_session_cutover_test.rb chatwoot_widget_session_gate_test.rb].each do |name|
      assert_includes gate, "'tests/#{name}'"
    end
    assert_includes gate, 'bundle exec ruby /contract/tests/chatwoot_widget_session_epoch_test.rb'
    assert_includes gate, 'bundle exec ruby /contract/tests/chatwoot_widget_session_cutover_test.rb'
    assert_includes gate, 'ruby "$CONTROL_ROOT/tests/chatwoot_widget_session_gate_test.rb"'
  end
end
