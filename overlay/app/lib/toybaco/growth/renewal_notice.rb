# frozen_string_literal: true

require_relative 'paid_period'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # The billing owner sees a deadline only while a fresh provider read still
    # confirms an open renewal. Cached failure events alone are not a notice.
    class RenewalNotice
      def initialize(account, subscription:, now: Time.now.utc)
        @account = account
        @subscription = subscription
        @now = now
      end

      def summary
        return unless unpaid_renewal?

        grace = RenewalGrace.new(@account, now: @now)
        expired = grace.expired?
        return unless expired || grace.active?

        failure = Entitlements.attributes(@account).fetch(RenewalGrace::FAILURE_KEY)
        { expired: expired, deadline: Time.at(failure.fetch('grace_ends_at')).utc.iso8601 }
      end

      private

      def unpaid_renewal?
        id = Entitlements.attributes(@account)['toybaco_subscription_id']
        return false unless @subscription.is_a?(Hash) && @subscription['id'] == id && %w[active past_due unpaid].include?(@subscription['status'])

        invoice = @subscription['latest_invoice']
        open_renewal?(invoice) && (invoice['subscription'] || invoice.dig('parent', 'subscription_details', 'subscription')) == id
      end

      def open_renewal?(invoice)
        invoice.is_a?(Hash) && invoice['status'] == 'open' && invoice['billing_reason'] == 'subscription_cycle' &&
          invoice['currency'] == 'jpy' && invoice['amount_remaining'].is_a?(Integer) && invoice['amount_remaining'].positive? &&
          invoice['id'].to_s.match?(/\Ain_[A-Za-z0-9]+\z/)
      end
    end
  end
end
