# frozen_string_literal: true

require_relative '../connections/gmail'
require_relative '../connections/microsoft'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class OnboardingInboxes
      TYPES = %w[Channel::Email Channel::Line].freeze

      def initialize(account, user, administrator:)
        @account = account
        @user = user
        @administrator = administrator
      end

      # ガイドで案内する候補。スタッフには所属している受信箱だけを見せる。
      def visible
        scope = store_inboxes
        scope = scope.joins(:inbox_members).where(inbox_members: { user_id: @user.id }) unless @administrator
        scope.select { |inbox| usable?(inbox.channel) }
      end

      # 店舗全体に、ガイドの対象になる受信箱があるか(所属では絞らない)。
      def any_in_store?
        store_inboxes.any? { |inbox| usable?(inbox.channel) }
      end

      def describe(inbox)
        line = inbox.channel_type == 'Channel::Line'
        email = line ? nil : inbox.channel.email
        { 'id' => inbox.id, 'name' => inbox.name, 'email' => email, 'provider' => provider(inbox.channel),
          'label' => line ? "#{inbox.name} · LINE公式" : email }
      end

      def accepted_reply?(reply, inbox)
        return false if reply.content_attributes['deleted']
        # The fixed native LINE sender sets delivered only after HTTP 200.
        # Its outgoing messages have no source_id; this is API acceptance, not
        # proof that the recipient read or received the message.
        return %w[delivered read].include?(reply.status) if inbox.channel_type == 'Channel::Line'
        return false if reply.source_id.blank?

        accepted_mail_reply?(reply, inbox)
      end

      private

      def store_inboxes
        @account.inboxes.where(channel_type: TYPES).includes(:channel).order(:created_at, :id)
      end

      def accepted_mail_reply?(reply, inbox)
        key = Connections::Microsoft.connected?(inbox.channel) ? 'toybaco_microsoft_send' : 'toybaco_gmail_send'
        receipt = reply.content_attributes[key]
        receipt.is_a?(Hash) && receipt['state'] == 'accepted' && receipt['provider_id'].present? && receipt['accepted_at'].present?
      end

      def provider(channel)
        return 'line' if channel.is_a?(Channel::Line)

        Connections::Gmail.connected?(channel) ? 'gmail' : 'microsoft'
      end

      def usable?(channel)
        return line_configured?(channel) if channel.is_a?(Channel::Line)
        return false if channel.reauthorization_required?
        return Connections::Gmail.allowed?(@account) if Connections::Gmail.connected?(channel)

        Connections::Microsoft.application_current?(channel) && Connections::Microsoft.allowed?(@account)
      end

      def line_configured?(channel)
        channel.line_channel_id.present? && channel.line_channel_secret.present? && channel.line_channel_token.present?
      end
    end
  end
end
