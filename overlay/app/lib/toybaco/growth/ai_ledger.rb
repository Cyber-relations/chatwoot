# frozen_string_literal: true

require 'digest'
require 'securerandom'
require_relative '../entitlements'
require_relative 'free_period'
require_relative 'paid_period'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Store locking serializes reply, post and automation reservations together.
    # Support assistance never enters this ledger. No prompt/transcript is kept.
    class AiLedger
      LEASE_SECONDS = 300
      KINDS = %w[reply_draft post_draft automatic_reply].freeze

      class Conflict < StandardError; end

      def initialize(account, now: Time.now.utc)
        @account = account
        @now = now
      end

      def reserve(request_key:, kind:, context_digest:)
        validate_request!(request_key, kind, context_digest)
        @account.with_lock do
          FreePeriod.new(@account, now: @now).refresh!
          PaidPeriod.new(@account, now: @now).refresh!
          RenewalGrace.new(@account, now: @now).refresh!
          previous = operations.find_by(request_key: request_key)
          return duplicate(previous, kind, context_digest) if previous

          sources = allowed_sources(kind)
          grant = available_grant(sources)
          return { 'result' => 'denied', 'reason' => sources.empty? ? 'disabled' : 'limit_reached' } unless grant

          create_reservation(grant, request_key, kind, context_digest)
        end
      end

      def settle(operation_id:, token:, outcome:)
        validate_settlement!(outcome, block_given?)

        @account.with_lock do
          operation = operations.find_by(id: operation_id)
          return { 'result' => 'denied', 'reason' => 'invalid_reservation' } unless owns?(operation, token)
          return result_for(operation) unless operation.state == 'reserved'
          return finish_without_charge(operation, 'expired') if operation.lease_expires_at <= @now
          return finish_without_charge(operation, 'released') if outcome == 'released'
          return finish_without_charge(operation, 'released') unless consumption_allowed?(operation)

          reference = yield
          consume(operation, reference)
        end
      end

      def summary(kind: 'reply_draft')
        raise ArgumentError, 'unknown generation kind' unless KINDS.include?(kind)

        @account.with_lock do
          FreePeriod.new(@account, now: @now).refresh!
          PaidPeriod.new(@account, now: @now).refresh!
          RenewalGrace.new(@account, now: @now).refresh!
          grants = active_grants(allowed_sources(kind)).to_a
          reservations = reservation_counts(grants.map(&:id))
          remaining = grants.sum { |grant| [grant.units - grant.used - reservations.fetch(grant.id, 0), 0].max }
          { 'remaining' => remaining, 'grants' => grants.map { |grant| grant_summary(grant, reservations) } }
        end
      end

      private

      def validate_settlement!(outcome, persistence_given)
        raise ArgumentError, 'invalid settlement' unless %w[consumed released].include?(outcome)
        raise ArgumentError, 'a persisted result is required' if outcome == 'consumed' && !persistence_given
      end

      def operations
        Toybaco::GrowthAiOperation.where(account_id: @account.id)
      end

      def validate_request!(key, kind, digest)
        valid = key.is_a?(String) && key.match?(/\A[0-9a-f-]{16,80}\z/) && digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
        raise ArgumentError, 'invalid generation request' unless valid && KINDS.include?(kind)
      end

      def allowed_sources(kind)
        terms = Toybaco::Entitlements.for_account(@account)
        return [] unless generation_enabled?(terms)

        grace = RenewalGrace.new(@account, now: @now)
        return kind == 'automatic_reply' ? [] : ['pack'] if grace.expired?

        sources = paid_sources(grace)
        return sources unless kind == 'automatic_reply'

        terms.dig('features', 'ai_auto_reply') == true ? sources : ['trial']
      end

      def generation_enabled?(terms)
        @account.active? && terms && terms['ai_meter'] == Toybaco::GrowthTerms::METER && terms.dig('features', 'ai_reply') == true
      end

      def paid_sources(grace)
        sources = %w[included pack]
        sources << 'grace' if grace.active?
        sources
      end

      def active_grants(sources)
        receipt = FreeReturnRecord.current(@account)
        Toybaco::GrowthAiGrant.where(account_id: @account.id, source: sources, revoked_at: nil)
                              .where('starts_at <= ? AND ends_at > ?', @now, @now)
                              .order(Arel.sql("CASE source WHEN 'pack' THEN 1 ELSE 0 END"), :ends_at, :id)
                              .select { |grant| current_grant?(grant, receipt) }
      end

      def current_grant?(grant, receipt)
        return FreeReturnRecord.included_allowed?(@account, grant, receipt) if grant.source == 'included'

        grant.source != 'grace' || RenewalGrace.new(@account, now: @now).permits?(grant)
      end

      def reservation_counts(ids)
        operations.where(grant_id: ids, state: 'reserved').where('lease_expires_at > ?', @now).group(:grant_id).count
      end

      def available_grant(sources)
        grants = active_grants(sources).to_a
        reservations = reservation_counts(grants.map(&:id))
        grants.find { |grant| (grant.units - grant.used - reservations.fetch(grant.id, 0)).positive? }
      end

      def create_reservation(grant, key, kind, digest)
        token = SecureRandom.hex(24)
        operation = operations.create!(grant: grant, request_key: key, kind: kind, context_digest: digest,
                                       token_digest: Digest::SHA256.hexdigest(token), lease_expires_at: @now + LEASE_SECONDS)
        { 'result' => 'reserved', 'operation_id' => operation.id, 'token' => token }
      end

      def duplicate(operation, kind, digest)
        raise Conflict, 'request key already belongs to another generation' unless operation.kind == kind && operation.context_digest == digest

        operation.update!(state: 'expired') if operation.state == 'reserved' && operation.lease_expires_at <= @now
        result_for(operation)
      end

      def result_for(operation)
        { 'result' => 'duplicate', 'state' => operation.state, 'operation_id' => operation.id, 'result_reference' => operation.result_reference }
      end

      def owns?(operation, token)
        operation && token.to_s.match?(/\A[0-9a-f]{48}\z/) &&
          ActiveSupport::SecurityUtils.secure_compare(operation.token_digest, Digest::SHA256.hexdigest(token))
      end

      def consumption_allowed?(operation)
        grant = operation.grant
        return false if grant.revoked_at || allowed_sources(operation.kind).exclude?(grant.source)
        return false if grant.source == 'trial' && grant.ends_at <= @now
        return false if grant.source == 'grace' && !RenewalGrace.new(@account, now: @now).permits?(grant)

        # A request begun before the monthly boundary may finish within its
        # five-minute lease, using the bucket it actually reserved.
        grant.used < grant.units
      end

      def consume(operation, reference)
        raise ArgumentError, 'invalid persisted result' unless reference.is_a?(String) && !reference.empty? && reference.length <= 160

        operation.grant.update!(used: operation.grant.used + 1)
        operation.update!(state: 'consumed', result_reference: reference)
        { 'result' => 'consumed', 'operation_id' => operation.id, 'result_reference' => reference }
      end

      def finish_without_charge(operation, state)
        operation.update!(state: state)
        { 'result' => state, 'operation_id' => operation.id }
      end

      def grant_summary(grant, reservations)
        { 'source' => grant.source, 'limit' => grant.units, 'used' => grant.used, 'reserved' => reservations.fetch(grant.id, 0),
          'expires_at' => grant.ends_at.utc.iso8601 }
      end
    end
  end
end
