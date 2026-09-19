# frozen_string_literal: true

# Called only by the staging workflow after the fixed model probe succeeds.
# Disabling remains possible during a model outage. No other feature is opened.
module ToybacoSupportStagingFlags
  KEYS = %w[TOYBACO_SUPPORT_ENABLED TOYBACO_SUPPORT_AI_ENABLED].freeze
  REPORTS = 'TOYBACO_SUPPORT_REPORTS_ENABLED'
  LOCK = 6_538_221_007_831
  class Invalid < StandardError; end

  def self.apply!(enabled:, environment: ENV)
    raise Invalid unless environment['TOYBACO_DEPLOYMENT_ENVIRONMENT'] == 'staging' && [true, false].include?(enabled)
    raise Invalid unless Toybaco::Support::Knowledge::VERSION == '2026-09-19.2'

    InstallationConfig.transaction do
      InstallationConfig.connection.execute("SELECT pg_advisory_xact_lock(#{LOCK})")
      verify_reports!(enabled)
      update_flags!(enabled)
    end
    GlobalConfig.clear_cache
    raise Invalid unless KEYS.all? { |key| InstallationConfig.find_by!(name: key).value == enabled }

    puts "TOYBACO_SUPPORT_STAGING_UI=PASS state=#{enabled ? 'enabled' : 'disabled'} reports=unchanged"
  end

  def self.verify_reports!(enabled)
    reports = InstallationConfig.find_by(name: REPORTS)
    raise Invalid if enabled && reports && [nil, false, 'false'].exclude?(reports.value)
  end

  def self.update_flags!(enabled)
    records = KEYS.map { |key| InstallationConfig.find_or_initialize_by(name: key) }
    raise Invalid unless records.all? { |record| [nil, false, true, 'false', 'true'].include?(record.value) }

    records.each do |record|
      next if record.persisted? && record.value == enabled

      record.value = enabled
      record.locked = false
      record.save!
    end
  end

  private_class_method :verify_reports!, :update_flags!
end
