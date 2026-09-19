# frozen_string_literal: true

require_relative 'annual_renewal_context'
require_relative 'renewal_reminder'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class AnnualRenewalReminder
      include AnnualRenewalContext
      KEY = 'toybaco_growth_annual_renewal_reminder'
      TERMINAL = %w[dispatching attempted uncertain].freeze

      def initialize(account, client: nil, now: Time.now.utc)
        @account = account
        @client = client
        @now = now
      end

      def perform
        return unless RenewalReminder.enabled? && claim!

        Toybaco::GrowthAnnualRenewalMailer.reminder(@account.id, @recipient_id, @renewal, @stage, @deadline).deliver_now
        finish!('attempted')
      rescue StandardError => e
        finish!('uncertain') if @claimed
        Rails.logger.warn("toybaco_annual_renewal_reminder_uncertain account=#{@account.id} class=#{e.class.name}")
      end

      private

      def claim!
        @account.with_lock do
          return false unless eligible?

          owner = TrialNotice.owner(@account)
          return false unless owner
          return false unless current_term(client.retrieve_subscription(@attrs.fetch('toybaco_subscription_id')))

          prepare_record
          return false unless due?

          claim_delivery!(owner)
        end
      end

      def prepare_record
        previous = @attrs[KEY]
        @record = previous.is_a?(Hash) && previous['renewal'] == @renewal ? previous.deep_dup : { 'renewal' => @renewal, 'stages' => {} }
      end

      def due?
        @record['stages'].is_a?(Hash) && TERMINAL.exclude?(@record.dig('stages', @stage, 'state'))
      end

      def claim_delivery!(owner)
        @recipient_id = owner.id
        @token = SecureRandom.hex(16)
        @record['stages'][@stage] = { 'state' => 'dispatching', 'token' => @token, 'user_id' => owner.id, 'attempted_at' => @now.to_i }
        @account.update!(internal_attributes: @attrs.merge(KEY => @record))
        @claimed = true
      end

      def client
        @client ||= Checkout::Client.new(ENV.fetch('TOYBACO_STRIPE_KEY', ''))
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
