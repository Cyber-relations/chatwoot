# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # A provider approval belongs to one application and scope set. UI visibility
  # must not turn a draft submission, a brand verification, or staging smoke into
  # permission to connect production customers. Read on every request so a
  # recorded approval/revocation takes effect without rebuilding the application.
  class ConnectionRelease
    CONFIG_NAME = 'TOYBACO_CONNECTION_RELEASES'
    ENVIRONMENTS = %w[staging production].freeze
    REQUIRED_CHECKS = %w[authorization callback receive reply disconnect tenant_isolation].freeze

    attr_reader :environment

    def initialize(environment:, records: {}, now: Time.now.utc)
      @environment = environment
      @records = records.is_a?(Hash) ? records : {}
      @now = now
    end

    def self.current
      # An absent deployment environment is not a production authorization.
      setting = InstallationConfig.find_by(name: CONFIG_NAME)&.value
      new(environment: ENV.fetch('TOYBACO_DEPLOYMENT_ENVIRONMENT', nil), records: setting)
    end

    def self.scope_digest(scopes)
      Digest::SHA256.hexdigest(JSON.generate(scopes.map(&:to_s).uniq.sort))
    end

    def decision(provider:, application_id:, scopes:, implementation_revision:, qualification_required: false)
      reason = configuration_error(application_id, scopes, implementation_revision)
      return denied(reason) if reason

      record = @records.dig(environment, provider.to_s)
      identity = { 'application_id' => application_id.to_s, 'scope_digest' => self.class.scope_digest(scopes) }
      reason = approval_error(record, identity, qualification_required)
      return denied(reason) if reason

      expected = identity.merge('implementation_revision' => implementation_revision.to_s, 'environment' => environment)
      return denied('connection_check_pending') unless checked?(record['smoke'], expected)

      { 'available' => true, 'reason' => nil }
    rescue TypeError, ArgumentError
      denied('configuration_invalid')
    end

    private

    def configuration_error(application_id, scopes, revision)
      return 'environment_unknown' unless ENVIRONMENTS.include?(environment)
      return 'implementation_unavailable' if revision.to_s.empty?
      return 'application_unconfigured' if application_id.to_s.empty?
      return 'scope_unconfigured' unless scopes.is_a?(Array) && !scopes.empty?
    end

    def approval_error(record, identity, qualification_required)
      return 'review_pending' unless record.is_a?(Hash)
      return 'disabled' if record['disabled'] == true
      return 'revoked' if matches?(record['approval'], 'status' => 'revoked')
      return 'review_pending' unless approved?(record['approval'], identity)

      return 'qualification_pending' unless qualified?(record, identity, qualification_required)
    end

    def qualified?(record, identity, required)
      return true unless required || record.key?('qualification')

      approved?(record['qualification'], identity)
    end

    def approved?(receipt, identity)
      matches?(receipt, identity) && receipt['status'] == 'approved' && evidence?(receipt) && unexpired?(receipt)
    end

    def checked?(smoke, expected)
      matches?(smoke, expected) && evidence?(smoke) && REQUIRED_CHECKS.all? { |check| smoke.dig('checks', check) == true }
    end

    def matches?(value, expected)
      value.is_a?(Hash) && expected.all? { |key, item| value[key] == item }
    end

    def evidence?(record)
      !record['evidence_ref'].to_s.strip.empty? && valid_time?(record['observed_at'])
    end

    def valid_time?(value)
      parsed = Time.iso8601(value.to_s)
      parsed <= @now
    rescue ArgumentError
      false
    end

    def unexpired?(record)
      return true unless record.key?('expires_at')

      Time.iso8601(record['expires_at'].to_s) > @now
    rescue ArgumentError
      false
    end

    def denied(reason)
      { 'available' => false, 'reason' => reason }
    end
  end
end
