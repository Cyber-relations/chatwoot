# frozen_string_literal: true

require 'minitest/autorun'
require 'ostruct'
require 'rake'
require 'time'

# Exercise the real initializer without loading Rails or contacting a database.
module Rails
  def self.env
    @environment
  end

  def self.application
    @application
  end

  def self.configure_fixture(production:)
    @environment = OpenStruct.new(production?: production)
    # Upstream config.x is a HashWithIndifferentAccess, not OrderedOptions.
    # A plain Hash reproduces its lack of method-style configuration accessors.
    @application = OpenStruct.new(config: OpenStruct.new(x: {}))
  end
end

class ChatwootWidgetSessionEpochTest < Minitest::Test
  INITIALIZER = File.expand_path('../overlay/app/config/initializers/toybaco_widget_session_epoch.rb', __dir__)
  VARIABLE = 'TOYBACO_WIDGET_SESSION_SECURITY_EPOCH'

  def setup
    @previous = ENV[VARIABLE]
    @previous_rake = Rake.application
    @previous_argv = ARGV.dup
    Rake.application = Rake::Application.new
    Rails.configure_fixture(production: true)
  end

  def teardown
    @previous.nil? ? ENV.delete(VARIABLE) : ENV[VARIABLE] = @previous
    Rake.application = @previous_rake
    ARGV.replace(@previous_argv)
  end

  def configure(value)
    value.nil? ? ENV.delete(VARIABLE) : ENV[VARIABLE] = value
    load INITIALIZER
    Toybaco::Security::WidgetSessionSecurityEpoch.lower_bound
  end

  def test_production_requires_an_explicit_cutover
    error = assert_raises(RuntimeError) { configure(nil) }
    assert_equal 'TOYBACO_WIDGET_SESSION_SECURITY_EPOCH must be set to the widget cutover time', error.message
  end

  def test_configured_cutover_is_fixed_across_initializations
    first = configure('2026-11-04T09:00:00Z')
    second = configure('2026-11-04T09:00:00Z')
    assert_equal Time.utc(2026, 11, 4, 9), first
    assert_equal first, second
    assert first.frozen?
    assert_empty Rails.application.config.x
  end

  def test_explicit_timezone_is_normalized_to_the_same_instant
    assert_equal configure('2026-11-04T09:00:00Z'), configure('2026-11-04T18:00:00+09:00')
  end

  def test_subsecond_timestamps_preserve_database_precision
    assert_equal Time.iso8601('2026-11-04T09:00:00.123456Z'), configure('2026-11-04T18:00:00.123456+09:00')
  end

  def test_missing_timezone_empty_and_malformed_values_fail_closed
    ['', 'today', '2026-11-04', '2026-11-04T09:00:00', '2026-13-04T09:00:00Z', '2026-02-31T09:00:00Z',
     '2026-11-04T24:00:00Z', '2026-11-04T09:60:00Z', '2026-11-04T09:00:60Z',
     '2026-11-04T09:00:00+24:00', '2026-11-04T09:00:00+09:60', '2026-11-04T09:00:00.1234567Z'].each do |value|
      error = assert_raises(RuntimeError) { configure(value) }
      assert_equal 'Widget session security epoch must be an ISO 8601 timestamp with timezone', error.message
    end
  end

  def test_development_and_test_boot_without_deployment_configuration
    Rails.configure_fixture(production: false)
    assert_equal Time.at(0).utc, configure(nil)
    assert_equal Time.utc(2026, 11, 4, 9), configure('2026-11-04T09:00:00Z')
  end

  def invoke_rake(arguments, value = nil)
    ARGV.replace(arguments)
    Rake.application.init
    Rake::Task.define_task(:environment) { configure(value) }
    %w[assets:precompile db:prepare toybaco:widget_session_security_cutover].each do |name|
      Rake::Task.define_task(name => :environment)
    end
    Rake.application.top_level
    Toybaco::Security::WidgetSessionSecurityEpoch.lower_bound
  end

  def test_production_asset_precompilation_boots_without_an_epoch
    assert_equal Time.at(0).utc, invoke_rake(['assets:precompile'])
    assert_empty Rails.application.config.x
  end

  def test_production_asset_precompilation_respects_a_supplied_epoch
    assert_equal Time.utc(2026, 11, 4, 9), invoke_rake(['assets:precompile'], '2026-11-04T09:00:00Z')
  end

  def test_production_processes_boot_with_a_valid_epoch
    %w[server sidekiq runner].each do |command|
      ARGV.replace([command])
      assert_equal Time.utc(2026, 11, 4, 9), configure('2026-11-04T09:00:00Z')
    end
  end

  def test_precompile_is_detected_from_parsed_tasks_including_rake_options
    assert_equal Time.at(0).utc, invoke_rake(['--silent', 'assets:precompile', 'BUILD=1'])
  ensure
    ENV.delete('BUILD')
  end

  def test_a_task_name_in_argv_does_not_exempt_servers_workers_or_runners
    %w[server sidekiq runner].each do |command|
      ARGV.replace([command, 'assets:precompile'])
      assert_raises(RuntimeError) { configure(nil) }
      assert_raises(RuntimeError) { configure('malformed') }
    end
  end

  def test_loading_rake_and_parsing_the_asset_task_is_not_enough_to_skip_validation
    ARGV.replace(['assets:precompile'])
    Rake.application.init
    Rake::Task.define_task('assets:precompile')
    assert_raises(RuntimeError) { configure(nil) }
  end

  def test_production_one_off_tasks_still_require_the_epoch
    %w[db:prepare toybaco:widget_session_security_cutover].each do |task|
      Rake.application = Rake::Application.new
      assert_raises(RuntimeError) { invoke_rake([task]) }
      Rake.application = Rake::Application.new
      assert_raises(RuntimeError) { invoke_rake([task], 'malformed') }
      Rake.application = Rake::Application.new
      assert_equal Time.utc(2026, 11, 4, 9), invoke_rake([task], '2026-11-04T09:00:00Z')
    end
  end

  def test_mixed_asset_and_operational_tasks_do_not_bypass_validation
    assert_raises(RuntimeError) { invoke_rake(['assets:precompile', 'db:prepare']) }
  end

  def test_asset_precompilation_does_not_silently_accept_a_malformed_epoch
    assert_raises(RuntimeError) { invoke_rake(['assets:precompile'], 'malformed') }
  end
end
