# frozen_string_literal: true

require_relative 'access'
require_relative 'incorrect_code'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module Handoff
      class Verification
        def initialize(record)
          @record = record
        end

        def request!(token:, browser_nonce:)
          locked do
            Access.token!(@record, token)
            validate_nonce!(browser_nonce)
            raise Limited if @record.verification_send_count >= 3 || @record.verification_requested_at.to_i > Time.now.to_i - 60

            save_verification!(browser_nonce)
          end
          enqueue
        end

        def verify!(token:, browser_nonce:, code:)
          valid = locked do
            Access.token!(@record, token)
            validate_nonce!(browser_nonce)
            check_verification!(browser_nonce)
            accepted = accepted_code?(code)
            @record.update!(verification_attempts: @record.verification_attempts + 1)
            claim!(browser_nonce) if accepted
            accepted
          end
          # Preserve the failed-attempt count; never raise inside its transaction.
          raise IncorrectCode unless valid

          @record
        end

        def login!(token:, browser_nonce:, user:)
          locked do
            Access.token!(@record, token)
            validate_nonce!(browser_nonce)
            raise Forbidden unless user&.confirmed? && Access.equal?(@record.recipient_digest, Access.recipient_digest(user.email))

            claim!(browser_nonce)
          end
          @record
        end

        private

        def locked
          @record.account.with_lock do
            @record.with_lock do
              Access.current!(@record)
              yield
            end
          end
        end

        def save_verification!(browser_nonce)
          code = SecureRandom.random_number(1_000_000).to_s.rjust(6, '0')
          revision = SecureRandom.uuid
          @record.update!(verification_revision: revision, verification_digest: Access.code_digest(@record, revision, code),
                          encrypted_verification: Access.encode(@record, "code:#{revision}", code),
                          verification_browser_digest: Access.digest(browser_nonce), verification_attempts: 0,
                          verification_expires_at: [10.minutes.from_now, @record.expires_at].min,
                          verification_requested_at: Time.now.utc, verification_send_count: @record.verification_send_count + 1,
                          delivery_state: 'queued', delivery_attempted_at: nil)
        end

        def check_verification!(browser_nonce)
          raise Forbidden unless Access.equal?(@record.verification_browser_digest, Access.digest(browser_nonce))
          raise Forbidden unless @record.verification_expires_at && @record.verification_expires_at > Time.now.utc
          raise Limited if @record.verification_attempts >= 5
        end

        def accepted_code?(code)
          code.to_s.match?(/\A\d{6}\z/) && Access.equal?(@record.verification_digest,
                                                         Access.code_digest(@record, @record.verification_revision, code))
        end

        def validate_nonce!(value)
          raise Invalid unless value.to_s.match?(Access::SECRET)
        end

        def claim!(nonce)
          @record.update!(Access::PRIVATE_FIELDS.merge(state: 'claimed', claimed_at: Time.now.utc, claim_digest: Access.digest(nonce),
                                                       delivery_state: @record.delivery_state == 'queued' ? 'cancelled' : @record.delivery_state))
        end

        def enqueue
          Toybaco::ConnectionHandoffMailJob.perform_later(@record.id, @record.verification_revision)
        rescue StandardError => e
          Rails.logger.warn("toybaco_handoff_queue_pending id=#{@record.id} class=#{e.class}")
          # The queued record is durable; the sweep can retry queue admission.
          nil
        end
      end
    end
  end
end
