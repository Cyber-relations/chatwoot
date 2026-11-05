# frozen_string_literal: true

require 'time'

# The asset-only build loads this initializer before Rails' main autoloader.
module Toybaco; end
module Toybaco::Security; end

module Toybaco::Security::WidgetSessionSecurityEpoch
  VARIABLE = 'TOYBACO_WIDGET_SESSION_SECURITY_EPOCH'
  CONFIG_NAME = 'TOYBACO_WIDGET_SESSION_SECURITY_CUTOVER'
  TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,6})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)\z/

  class << self
    attr_accessor :lower_bound
  end

  module_function

  def configure!
    value = ENV.fetch(VARIABLE) do
      raise 'TOYBACO_WIDGET_SESSION_SECURITY_EPOCH must be set to the widget cutover time' if Rails.env.production? && !asset_precompilation?

      '1970-01-01T00:00:00Z'
    end
    self.lower_bound = parse(value).freeze
  end

  # Use Rake's parsed, actually invoked task, not ARGV substrings or an ENV bypass.
  # A mixed invocation (assets:precompile db:migrate, for example) still needs the epoch.
  def asset_precompilation?
    defined?(Rake) && Rake.application.top_level_tasks == ['assets:precompile'] &&
      Rake::Task.task_defined?('assets:precompile') && Rake::Task['assets:precompile'].already_invoked
  end

  def parse(value)
    raise ArgumentError unless value.is_a?(String) && value.match?(TIMESTAMP)

    Date.iso8601(value[0, 10])
    Time.iso8601(value).utc
  rescue ArgumentError
    raise 'Widget session security epoch must be an ISO 8601 timestamp with timezone'
  end

  def effective
    # GlobalConfig/Redis and ActiveRecord's query cache can both retain an older
    # value across cutover. Every validity check must observe the committed row.
    row = InstallationConfig.uncached { InstallationConfig.find_by(name: CONFIG_NAME) }
    [lower_bound, row && parse(row.value)].compact.max
  end

  # Hold this before validating a parent and until its descendants commit.
  # Shared locks let creators run concurrently; advance! waits for all of them.
  def with_creation_lock
    InstallationConfig.transaction do
      InstallationConfig.connection.execute("SELECT pg_advisory_xact_lock_shared(hashtext('#{CONFIG_NAME}'))")
      yield
    end
  end

  def advance!
    InstallationConfig.uncached do
      InstallationConfig.transaction do
        # Also serialize first creation, when there is no config row to lock yet.
        InstallationConfig.connection.execute("SELECT pg_advisory_xact_lock(hashtext('#{CONFIG_NAME}'))")
        row = InstallationConfig.lock.find_or_initialize_by(name: CONFIG_NAME)
        save_cutover!(row, parse(Time.now.utc.iso8601(6)))
      end
    end
  end

  def save_cutover!(row, requested)
    previous = parse(row.value) if row.persisted?
    cutover = [lower_bound, previous, requested, committed_creation_cutoff].compact.max
    row.value = cutover.iso8601(6)
    row.locked = true
    row.save! if row.changed?
    [parse(row.value), previous.nil? || cutover > previous]
  end
  private_class_method :save_cutover!

  # Read under the exclusive creation lock, after all earlier creators commit.
  # Their clocks may be ahead of ours; equality still authorizes a session.
  def committed_creation_cutoff
    latest = [Toybaco::WidgetSessionRecord.maximum(:created_at), Toybaco::WidgetHandoff.maximum(:created_at)].compact.max
    latest + Rational(1, 1_000_000) if latest
  end
  private_class_method :committed_creation_cutoff
end
