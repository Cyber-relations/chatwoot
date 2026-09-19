# frozen_string_literal: true

require_relative 'microsoft_parts'
require_relative '../entitlements'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    class MicrosoftIngest
      KEY = 'toybaco_microsoft_received'

      def initialize(channel, data, api:, access_token:)
        @channel = channel
        @data = data
        limit = Entitlements.for_account(channel.account)&.dig('limits', 'inbound_attachment_bytes') || MicrosoftApi::MAX_ATTACHMENT_BYTES
        @parts = MicrosoftParts.new(api: api, access_token: access_token, data: data,
                                    attachment_limit: limit, attachment_count: Message::NUMBER_OF_PERMITTED_ATTACHMENTS)
      end

      def call
        id = @parts.message_id
        return if @channel.inbox.messages.exists?(source_id: id)
        return if Imap::DeletedMessageTracker.new(inbox: @channel.inbox).deleted?(id)

        mail = @parts.mail
        Message.transaction do
          Imap::ImapMailbox.new.process(mail, @channel)
          message = @channel.inbox.messages.find_by(source_id: mail.message_id)
          record!(message) if message
        end
      end

      private

      def record!(message)
        receipt = { 'provider_id' => @data.fetch('id'), 'thread_id' => @data['conversationId'],
                    'received_at' => Time.now.utc.iso8601, 'omitted_attachments' => @parts.omissions }
        message.update!(content_attributes: message.content_attributes.merge(KEY => receipt))
        return if @parts.omissions.empty?

        message.conversation.messages.create!(account_id: @channel.account_id, inbox_id: @channel.inbox.id,
                                              message_type: :activity, private: true, content: omission_notice)
      end

      def omission_notice
        reasons = @parts.omissions.map { |item| item.fetch('reason') }.uniq
        labels = { 'file_too_large' => '添付25MBの上限', 'attachment_count' => '添付数の上限', 'not_available' => '提供元で取得不可' }
        detail = reasons.map { |reason| labels.fetch(reason) }.join('・')
        "添付#{@parts.omissions.length}件を保存できませんでした（#{detail}）。元のメールをご確認ください。"
      end
    end
  end
end
