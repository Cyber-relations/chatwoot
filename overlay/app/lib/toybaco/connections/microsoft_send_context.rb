# frozen_string_literal: true

require 'digest'
require 'json'
require_relative '../growth/reply_delivery'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    class MicrosoftSendContext
      def initialize(message)
        @message = message
      end

      def digest
        files = @message.attachments.includes(:file_attachment).order(:id).map { |file| [file.id, file.file_attachment&.blob_id] }
        attributes = @message.content_attributes.except('toybaco_microsoft_send', 'external_error')
        values = [@message.content, @message.private, @message.message_type, @message.sender_type, @message.sender_id,
                  @message.inbox_id, @message.conversation_id, attributes, files]
        Digest::SHA256.hexdigest(JSON.generate(values))
      end

      def allowed?
        return false unless @message.email_notifiable_message? && @message.account.active?

        return Growth::ReplyDelivery.new(@message).sendable? if @message.additional_attributes.key?(Growth::ReplyResult::KEY)
        return user_allowed? if @message.sender_type == 'User'
        return bot_allowed? if @message.sender_type == 'AgentBot'

        # Existing system-generated templates retain their channel behavior.
        @message.template?
      end

      private

      def user_allowed?
        user = User.find_by(id: @message.sender_id)
        return false unless user&.confirmed?

        account = @message.account
        membership = account.account_users.find_by(user_id: user.id)
        membership && ConversationPolicy.new({ user: user, account: account, account_user: membership }, @message.conversation).show?
      end

      def bot_allowed?
        bot = AgentBot.find_by(id: @message.sender_id)
        bot && @message.conversation.pending? && bot.agent_bot_inboxes.where(status: :active).exists?(inbox_id: @message.inbox_id)
      end
    end
  end
end
