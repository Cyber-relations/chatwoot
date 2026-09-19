# frozen_string_literal: true

require_relative 'completion'
require_relative '../line_setup_api'
require_relative '../../entitlements'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module Handoff
      class LineSetup
        FIELDS = %w[line_channel_id line_channel_secret line_channel_token].freeze

        def self.available?
          Access.enabled? && Chatwoot.encryption_configured? &&
            FIELDS.drop(1).all? { |field| Channel::Line.encrypted_attributes&.include?(field.to_sym) }
        end

        def initialize(record, api: LineSetupApi.new)
          @record = record
          @api = api
        end

        def save!(browser_nonce:, fields:)
          raise Unavailable unless self.class.available?
          raise Forbidden unless @record.provider == 'line'

          @fields = validate_fields!(fields)
          Completion.new(@record).commit!(browser_nonce: browser_nonce) do |account, _provider, inbox_id|
            @api.verify!(channel_id: @fields.fetch('line_channel_id'), access_token: @fields.fetch('line_channel_token'))
            save_inbox!(account, inbox_id)
          end
        ensure
          @fields = nil
        end

        private

        def validate_fields!(fields)
          raise Invalid unless fields.is_a?(Hash) && fields.keys.sort == FIELDS
          raise Invalid unless fields.values.all?(String)
          raise Invalid unless fields['line_channel_id'].match?(/\A\d{5,20}\z/)
          raise Invalid unless fields['line_channel_secret'].match?(/\A[0-9a-fA-F]{32}\z/)
          raise Invalid unless fields['line_channel_token'].match?(%r{\A[A-Za-z0-9+/=_-]{20,4096}\z})

          fields
        end

        def update_existing!(inbox)
          raise Forbidden unless inbox.channel.line_channel_id == @fields.fetch('line_channel_id')

          inbox.channel.update!(@fields)
          inbox.channel.encrypt
          inbox
        end

        def save_inbox!(account, inbox_id)
          return update_existing!(account.inboxes.find(inbox_id)) if inbox_id

          raise Invalid if Channel::Line.exists?(line_channel_id: @fields.fetch('line_channel_id'))

          limit = Toybaco::Entitlements.for_account(account)&.dig('limits', 'inboxes')
          raise Limited if limit && account.inboxes.count >= limit

          channel = Channel::Line.create!(@fields.merge('account' => account))
          account.inboxes.create!(channel: channel, name: "#{account.name.to_s.slice(0, 60)} LINE")
        end
      end
    end
  end
end
