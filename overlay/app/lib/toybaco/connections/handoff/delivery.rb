# frozen_string_literal: true

require_relative 'access'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module Handoff
      class Delivery
        def initialize(record, revision)
          @record = record
          @revision = revision
        end

        def perform
          values = claim!
          return unless values

          Toybaco::ConnectionHandoffMailer.verification(*values).deliver_now
          finish!('attempted')
        rescue Unavailable
          nil
        rescue StandardError => e
          Rails.logger.warn("toybaco_handoff_delivery_uncertain id=#{@record.id} class=#{e.class}")
          finish!('uncertain')
        end

        private

        def claim!
          @record.account.with_lock do
            @record.with_lock do
              return unless @record.state == 'issued' && @record.delivery_state == 'queued' && @record.verification_revision == @revision
              return cancel! unless @record.verification_expires_at && @record.verification_expires_at > Time.now.utc

              values = verified_values
              return unless values

              @record.update!(delivery_state: 'dispatching', delivery_attempted_at: Time.now.utc, encrypted_verification: nil)
              values
            end
          end
        end

        def verified_values
          Access.current!(@record)
          [Access.decode(@record, 'recipient', @record.encrypted_recipient),
           Access.decode(@record, "code:#{@revision}", @record.encrypted_verification)]
        rescue Forbidden, ActiveSupport::MessageEncryptor::InvalidMessage
          cancel!
        end

        def finish!(state)
          @record.with_lock do
            @record.update!(delivery_state: state) if @record.delivery_state == 'dispatching' && @record.verification_revision == @revision
          end
        end

        def cancel!
          @record.update!(delivery_state: 'cancelled', encrypted_verification: nil, verification_digest: nil)
          nil
        end
      end
    end
  end
end
