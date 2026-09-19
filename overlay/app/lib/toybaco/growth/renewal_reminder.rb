# frozen_string_literal: true

require_relative 'renewal_notice'
require_relative 'trial_notice'
require_relative '../checkout'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # A durable at-most-once attempt for each renewal and notice stage. An SMTP
    # timeout is uncertain, never a reason to send the same email again.
    class RenewalReminder
      KEY = 'toybaco_growth_renewal_reminder'
      TERMINAL = %w[attempted uncertain cancelled].freeze

      def self.enabled?
        GlobalConfigService.load('TOYBACO_GROWTH_NOTICES_ENABLED', false) == true
      end

      def initialize(account, client: nil, now: Time.now.utc)
        @account = account
        @client = client
        @now = now
      end

      def perform
        return unless self.class.enabled? && claim!

        Toybaco::GrowthRenewalMailer.reminder(@account.id, @recipient_id, @stage, @deadline).deliver_now
        finish!('attempted')
      rescue StandardError => e
        finish!('uncertain') if @claimed
        Rails.logger.warn("toybaco_renewal_reminder_uncertain account=#{@account.id} class=#{e.class.name}")
      end

      private

      def claim!
        @account.with_lock do
          return false unless eligible?

          prepare_record
          return false unless due?

          owner = TrialNotice.owner(@account)
          return defer! unless owner

          subscription = client.retrieve_subscription(@failure.fetch('subscription_id'))
          return cancel! unless current_unpaid?(subscription)

          notice = RenewalNotice.new(@account, subscription: subscription, now: @now).summary
          return cancel! unless notice

          claim_delivery!(owner, notice)
        end
      end

      def prepare_record
        previous = @attrs[KEY]
        @record = previous.is_a?(Hash) && previous['renewal'] == @renewal ? previous.deep_dup : { 'renewal' => @renewal, 'stages' => {} }
      end

      def claim_delivery!(owner, notice)
        @deadline = notice.fetch(:deadline)
        @recipient_id = owner.id
        @token = SecureRandom.hex(16)
        @record['stages'][@stage] = { 'state' => 'dispatching', 'token' => @token, 'user_id' => owner.id, 'attempted_at' => @now.to_i }
        save!
        @claimed = true
      end

      def eligible?
        @attrs = Entitlements.attributes(@account)
        @failure = @attrs[RenewalGrace::FAILURE_KEY]
        return false unless @account.active? && @failure.is_a?(Hash)
        return false unless @failure['subscription_id'] == @attrs['toybaco_subscription_id']
        return false unless valid_times?

        @renewal = "#{@failure['subscription_id']}:#{@failure['term_start']}"
        @stage = @now.to_i >= @failure['grace_ends_at'] ? 'expired' : 'initial'
        true
      end

      def valid_times?
        %w[term_start grace_ends_at].all? { |key| @failure[key].is_a?(Integer) && @failure[key].positive? }
      end

      def due?
        stages = @record['stages']
        return false unless stages.is_a?(Hash)
        return false if (TERMINAL + ['dispatching']).include?(stages.dig(@stage, 'state'))

        @record.fetch('next_check_at', 0).is_a?(Integer) && @record.fetch('next_check_at', 0) <= @now.to_i
      end

      def current_unpaid?(subscription)
        return false unless correct_subscription?(subscription)

        invoice = subscription['latest_invoice']
        invoice.is_a?(Hash) && invoice['id'] == @failure['invoice_id'] && invoice['status'] == 'open'
      end

      def correct_subscription?(subscription)
        mode = ENV.fetch('TOYBACO_STRIPE_MODE', 'live')
        subscription.is_a?(Hash) && %w[test live].include?(mode) && subscription['livemode'] == (mode == 'live') &&
          subscription['id'] == @failure['subscription_id'] && subscription['customer'] == @attrs['toybaco_stripe_customer_id'] &&
          @attrs['toybaco_stripe_customer_id'].to_s.match?(/\Acus_[A-Za-z0-9]+\z/)
      end

      def client
        @client ||= Checkout::Client.new(ENV.fetch('TOYBACO_STRIPE_KEY', ''))
      end

      def defer!
        @record['next_check_at'] = @now.to_i + 3600
        save!
        false
      end

      def cancel!
        %w[initial expired].each do |stage|
          @record['stages'][stage] ||= { 'state' => 'cancelled' }
        end
        save!
        false
      end

      def save!
        @account.update!(internal_attributes: Entitlements.attributes(@account).merge(KEY => @record))
      end

      def finish!(state)
        @account.with_lock do
          attrs = Entitlements.attributes(@account)
          record = attrs[KEY]
          return unless record.is_a?(Hash) && record['renewal'] == @renewal && record.dig('stages', @stage, 'token') == @token

          record['stages'][@stage]['state'] = state
          record['stages'][@stage].delete('token')
          @account.update!(internal_attributes: attrs.merge(KEY => record))
        end
      end
    end
  end
end
