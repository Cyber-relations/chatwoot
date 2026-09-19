# frozen_string_literal: true

require_relative 'access'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module Handoff
      class Issue
        def initialize(account, user)
          @account = account
          @user = user
        end

        def create!(request_id:, recipient:, provider:, inbox_id: nil)
          raise Unavailable unless Access.enabled?

          @email = recipient.to_s.strip.downcase
          validate!(request_id, provider, inbox_id)
          @scope = "#{provider}:#{inbox_id || 'new'}"
          @request_digest = Access.digest([Access.recipient_digest(@email), @scope].to_json)
          @account.with_lock do
            Access.administrator!(@account, @user)
            Access.target!(@account, provider, inbox_id)
            existing = records.find_by(request_id: request_id)
            return recover(existing) if existing
            raise Limited if records.where('created_at > ?', 24.hours.ago).count >= 10

            replace_current!
            record = new_record(request_id, provider, inbox_id)
            save_with_token!(record)
          end
        end

        def link_for(record)
          Access.administrator!(@account, @user)
          raise Forbidden unless record.account_id == @account.id
          return unless record.creator_id == @user.id && record.state == 'issued' && record.expires_at > Time.now.utc

          Access.current!(record)
          Access.decode(record, 'link', record.encrypted_token)
        end

        def revoke!(record)
          @account.with_lock do
            Access.administrator!(@account, @user)
            raise Forbidden unless record.account_id == @account.id

            record.with_lock { record.update!(Access::PRIVATE_FIELDS.merge(state: 'revoked')) unless record.state == 'completed' }
          end
        end

        private

        def validate!(request_id, provider, inbox_id)
          raise Invalid unless request_id.to_s.match?(Access::UUID) && Access::PROVIDERS.key?(provider)
          raise Invalid unless @email.bytesize <= 254 && @email.match?(URI::MailTo::EMAIL_REGEXP)

          validate_inbox_id!(inbox_id)
        end

        def validate_inbox_id!(value)
          raise Invalid unless value.nil? || (value.is_a?(Integer) && value.positive?)
        end

        def new_record(request_id, provider, inbox_id)
          records.new(creator_id: @user.id, public_id: SecureRandom.uuid, request_id: request_id,
                      request_digest: @request_digest, provider: provider, target_key: @scope, inbox_id: inbox_id,
                      recipient_digest: Access.recipient_digest(@email), expires_at: 24.hours.from_now)
        end

        def records
          Toybaco::ConnectionHandoff.where(account_id: @account.id)
        end

        def replace_current!
          records.where(target_key: @scope, state: %w[issued claimed]).find_each do |record|
            record.with_lock { record.update!(Access::PRIVATE_FIELDS.merge(state: 'revoked')) }
          end
        end

        def recover(record)
          raise Invalid unless record.creator_id == @user.id && record.request_digest == @request_digest
          return [record, nil] unless record.state == 'issued' && record.expires_at > Time.now.utc

          [record, Access.decode(record, 'link', record.encrypted_token)]
        end

        def save_with_token!(record)
          token = SecureRandom.hex(32)
          record.assign_attributes(token_digest: Access.digest(token), encrypted_token: Access.encode(record, 'link', token),
                                   encrypted_recipient: Access.encode(record, 'recipient', @email))
          record.save!
          [record, token]
        end
      end
    end
  end
end
