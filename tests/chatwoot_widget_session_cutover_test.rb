# frozen_string_literal: true

require 'minitest/autorun'
require 'rake'
require_relative '../overlay/app/lib/toybaco/security/widget_session_security_epoch'

# These fixtures execute the real rake/service without Rails or PostgreSQL.
# Native locking and query-cache behavior are covered separately by the Rails spec.
class InstallationConfig
  class << self
    attr_accessor :row, :events

    def uncached
      events << :uncached
      yield
    end

    def transaction
      events << :transaction
      yield
    end

    def connection
      self
    end

    def execute(sql)
      events << sql
    end

    def lock
      events << :row_lock
      self
    end

    def find_by(name:)
      events << [:read, name]
      row
    end

    def find_or_initialize_by(name:)
      events << [:write, name]
      row || new
    end
  end

  attr_accessor :value, :locked

  def persisted?
    self.class.row.equal?(self)
  end

  def changed?
    @saved_attributes != [value, locked]
  end

  def save!
    self.class.events << :save
    @saved_attributes = [value, locked]
    self.class.row = self
  end
end

class WidgetCreationFixture
  class << self
    attr_accessor :created_times

    def maximum(column)
      InstallationConfig.events << [:maximum, name, column]
      raise ArgumentError unless column == :created_at

      created_times.max
    end
  end
end

class Toybaco::WidgetSessionRecord < WidgetCreationFixture; end
class Toybaco::WidgetHandoff < WidgetCreationFixture; end

class ChatwootWidgetSessionCutoverTest < Minitest::Test
  EPOCH = Toybaco::Security::WidgetSessionSecurityEpoch
  TASK = 'toybaco:widget_session_security_cutover'
  BASELINE = Time.utc(2026, 11, 4, 9)
  NOW = Time.utc(2026, 11, 4, 10)
  ADVANCED = "TOYBACO_WIDGET_SESSION_SECURITY_CUTOVER=2026-11-04T10:00:00.000000Z\n" \
             "Widget session security cutover advanced.\n"
  STAYED = "TOYBACO_WIDGET_SESSION_SECURITY_CUTOVER=2026-11-04T10:00:00.000000Z\n" \
           "Widget session security cutover stayed.\n"

  def setup
    @previous_rake = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path('../overlay/app/lib/tasks/toybaco_widget_session_security.rake', __dir__)
    @previous_lower_bound = EPOCH.lower_bound
    EPOCH.lower_bound = BASELINE
    InstallationConfig.row = nil
    InstallationConfig.events = []
    Toybaco::WidgetSessionRecord.created_times = []
    Toybaco::WidgetHandoff.created_times = []
  end

  def teardown
    Rake.application = @previous_rake
    EPOCH.lower_bound = @previous_lower_bound
  end

  def invoke(now = NOW, *arguments)
    Rake::Task[TASK].reenable
    Time.stub(:now, now) { Rake::Task[TASK].invoke(*arguments) }
  end

  def test_no_argument_task_records_now_and_emits_exactly_two_safe_lines
    assert_empty Rake::Task[TASK].arg_names
    assert_output(ADVANCED, '') { invoke }
    assert_equal '2026-11-04T10:00:00.000000Z', InstallationConfig.row.value
    assert_equal true, InstallationConfig.row.locked
    assert_equal [:uncached, :transaction,
                  "SELECT pg_advisory_xact_lock(hashtext('TOYBACO_WIDGET_SESSION_SECURITY_CUTOVER'))",
                  :row_lock, [:write, EPOCH::CONFIG_NAME],
                  [:maximum, 'Toybaco::WidgetSessionRecord', :created_at],
                  [:maximum, 'Toybaco::WidgetHandoff', :created_at], :save], InstallationConfig.events
  end

  def cutover_output(time, status)
    "TOYBACO_WIDGET_SESSION_SECURITY_CUTOVER=#{time.iso8601(6)}\nWidget session security cutover #{status}.\n"
  end

  def test_cutover_covers_the_latest_session_or_grant_even_with_a_slower_writer_clock
    future = Time.iso8601('2026-11-04T10:00:00.200000Z')
    expected = Time.iso8601('2026-11-04T10:00:00.200001Z')
    [[future, nil], [nil, future], [future, NOW], [NOW, future]].each do |session, grant|
      InstallationConfig.row = nil
      Toybaco::WidgetSessionRecord.created_times = [BASELINE, session].compact
      Toybaco::WidgetHandoff.created_times = [BASELINE, grant].compact
      assert_output(cutover_output(expected, 'advanced'), '') { invoke(NOW + Rational(1, 10)) }
      assert_equal expected, EPOCH.effective
      assert_output(cutover_output(expected, 'stayed'), '') { invoke(NOW) }
    end
  end

  def test_a_creation_equal_to_now_requires_a_strictly_later_cutoff
    Toybaco::WidgetSessionRecord.created_times = [NOW]
    expected = Time.iso8601('2026-11-04T10:00:00.000001Z')
    assert_output(cutover_output(expected, 'advanced'), '') { invoke }
    assert_equal expected, EPOCH.effective
  end

  def test_the_microsecond_successor_carries_into_the_next_second
    Toybaco::WidgetHandoff.created_times = [Time.iso8601('2026-11-04T10:00:00.999999Z')]
    assert_output(cutover_output(NOW + 1, 'advanced'), '') { invoke }
    assert_equal NOW + 1, EPOCH.effective
  end

  def test_now_environment_and_previous_value_can_exceed_the_creation_bound
    Toybaco::WidgetSessionRecord.created_times = [BASELINE]
    Toybaco::WidgetHandoff.created_times = [BASELINE]
    assert_output(ADVANCED, '') { invoke }
    EPOCH.lower_bound = NOW + 2
    Toybaco::WidgetHandoff.created_times = [NOW + 1]
    assert_output(cutover_output(NOW + 2, 'advanced'), '') { invoke }
    EPOCH.lower_bound = BASELINE
    assert_output(cutover_output(NOW + 2, 'stayed'), '') { invoke }
    assert_equal NOW + 2, EPOCH.effective
  end

  def test_repeated_and_older_clocks_keep_the_later_time_and_emit_the_stayed_phrase
    assert_output(ADVANCED, '') { invoke }
    [NOW, BASELINE, NOW - 1].each do |now|
      assert_output(STAYED, '') { invoke(now) }
      assert_equal NOW, EPOCH.effective
    end
    assert_output("TOYBACO_WIDGET_SESSION_SECURITY_CUTOVER=2026-11-04T10:00:01.000000Z\n" \
                  "Widget session security cutover advanced.\n", '') { invoke(NOW + 1) }
    assert_equal NOW + 1, EPOCH.effective
  end

  def test_submicrosecond_clock_changes_do_not_claim_an_advance_without_a_new_recorded_time
    now = Time.iso8601('2026-11-04T10:00:00.123456789Z')
    timestamp = "TOYBACO_WIDGET_SESSION_SECURITY_CUTOVER=2026-11-04T10:00:00.123456Z\n"
    assert_output("#{timestamp}Widget session security cutover advanced.\n", '') { invoke(now) }
    assert_output("#{timestamp}Widget session security cutover stayed.\n", '') { invoke(now) }
  end

  def test_current_time_is_sampled_after_serializing_the_writer
    clock_reads = []
    clock = lambda do
      clock_reads << InstallationConfig.events.dup
      NOW
    end
    assert_output(ADVANCED, '') { invoke(clock) }
    assert_equal [:write, EPOCH::CONFIG_NAME], clock_reads.first.last
  end

  def test_creation_locks_the_same_cutover_key_before_reading_the_epoch
    result = EPOCH.with_creation_lock do
      assert_equal BASELINE, EPOCH.effective
      :created
    end
    assert_equal :created, result
    assert_equal [:transaction,
                  "SELECT pg_advisory_xact_lock_shared(hashtext('TOYBACO_WIDGET_SESSION_SECURITY_CUTOVER'))",
                  :uncached, [:read, EPOCH::CONFIG_NAME]], InstallationConfig.events
  end

  def test_environment_lower_bound_cannot_be_undercut_and_the_recorded_time_is_reported
    EPOCH.lower_bound = NOW
    assert_output(ADVANCED, '') { invoke(BASELINE) }
    EPOCH.lower_bound = BASELINE
    assert_equal NOW, EPOCH.effective
    EPOCH.lower_bound = NOW + 1
    assert_equal NOW + 1, EPOCH.effective
  end

  def test_reader_uses_the_direct_uncached_config_path
    assert_equal BASELINE, EPOCH.effective
    assert_equal [:uncached, [:read, EPOCH::CONFIG_NAME]], InstallationConfig.events
    assert_output(ADVANCED, '') { invoke }
    InstallationConfig.events = []
    assert_equal NOW, EPOCH.effective
    assert_equal [:uncached, [:read, EPOCH::CONFIG_NAME]], InstallationConfig.events
  end

  def test_any_arguments_are_rejected_without_output_or_config_access
    [['2026-11-04T12:00:00Z'], ['invalid'], ['now', 'extra']].each do |arguments|
      assert_output('', '') do
        error = assert_raises(ArgumentError) { invoke(NOW, *arguments) }
        assert_equal 'Widget session security cutover takes no arguments', error.message
      end
    end
    assert_nil InstallationConfig.row
    assert_empty InstallationConfig.events
  end

  def test_malformed_persisted_value_fails_closed_without_echoing_it_or_replacing_it
    row = InstallationConfig.new
    row.value = 'untrusted-stored-content'
    row.save!
    assert_raises(RuntimeError) { EPOCH.effective }
    assert_output('', '') do
      error = assert_raises(RuntimeError) { invoke }
      assert_equal 'Widget session security epoch must be an ISO 8601 timestamp with timezone', error.message
    end
    assert_equal 'untrusted-stored-content', row.value
  end
end
