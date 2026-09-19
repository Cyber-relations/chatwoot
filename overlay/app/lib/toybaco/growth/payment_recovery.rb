# frozen_string_literal: true

require_relative 'payment_dispatch'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module PaymentRecovery
      FIELDS = %w[receipt_id receipt_digest reviewed report_digest operator_reference].freeze
      class Invalid < StandardError; end
      module_function

      def retry!(report, now: Time.now.utc)
        validate!(report)
        event = Toybaco::GrowthPaymentEvent.find(report.fetch('receipt_id'))
        event.with_lock do
          raise Invalid unless report['receipt_digest'] == event.payload_digest

          previous = event.recovery_log.find { |entry| entry['operator_reference'] == report['operator_reference'] }
          if previous
            raise Invalid unless previous['report_digest'] == report['report_digest']
          else
            record!(event, report, now)
          end
        end
        PaymentDispatch.enqueue(event, now: now)
        event.reload.state
      end

      def validate!(report)
        raise Invalid unless reviewed_report?(report)
        raise Invalid unless report['receipt_id'].is_a?(Integer) && report['receipt_id'].positive?
        raise Invalid unless %w[receipt_digest report_digest].all? { |key| report[key].to_s.match?(/\A[0-9a-f]{64}\z/) }
        raise Invalid unless report['operator_reference'].to_s.match?(/\A[A-Za-z0-9][A-Za-z0-9:._-]{7,119}\z/)
      end

      def reviewed_report?(report)
        report.is_a?(Hash) && report.keys.sort == FIELDS.sort && report['reviewed'] == true
      end

      def record!(event, report, now)
        raise Invalid unless event.state == 'attention' && event.recovery_log.length < 100

        record = report.slice('operator_reference', 'report_digest').merge('reviewed_at' => now.iso8601, 'previous_attempts' => event.attempts)
        event.update!(state: 'pending', result: nil, lease_token: nil, lease_expires_at: nil, next_attempt_at: now,
                      attempt_limit: event.attempts + 20, recovery_log: event.recovery_log + [record])
      end
    end
  end
end
