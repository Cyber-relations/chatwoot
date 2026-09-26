# frozen_string_literal: true

require_relative '../entitlements'
require_relative '../inbound_email'
require_relative '../connections/gmail'
require_relative '../connections/microsoft'
require_relative '../connections/inbox_limit'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # 初回ガイドの「窓口をつなぐ」に出す受信箱の状況。数は種類を問わず店舗の全受信箱で数え、
    # 契約上限の判定(Connections::InboxLimit)と同じにする。宛先などの詳細は見てよい人にだけ返す。
    class OnboardingConnections
      def initialize(account, user, administrator:)
        @account = account
        @user = user
        @administrator = administrator
      end

      def read
        inboxes = @account.inboxes.includes(:channel).order(:id).to_a
        forwarding = forwarding_inbox(inboxes)
        # free は上限の案内の出し分けだけに使う(無料プランは「有料プランを見る」、それ以外はサポートへ)。
        { 'count' => inboxes.length, 'limit' => Entitlements.for_account(@account)&.dig('limits', 'inboxes'),
          'free' => Connections::InboxLimit.free_plan?(@account),
          'channels' => [(forwarding_row(forwarding) if forwarding), *provider_rows(inboxes - [forwarding].compact)].compact }
      end

      private

      # 開通時に自動作成する転送用「メール」受信箱(InboundEmail.provision! が記録した宛先と一致するもの)。
      def forwarding_inbox(inboxes)
        record = Entitlements.attributes(@account)[InboundEmail::ATTR_KEY]
        address = record['address'].to_s.downcase if record.is_a?(Hash) && record['status'] == 'ready'
        return if address.blank?

        inboxes.find { |inbox| inbox.channel_type == 'Channel::Email' && inbox.channel.email.to_s.downcase == address }
      end

      def forwarding_row(inbox)
        visible = @administrator || inbox.inbox_members.exists?(user_id: @user.id)
        { 'key' => 'email_forward', 'state' => 'ready', 'count' => 1, 'address' => (inbox.channel.email if visible) }
      end

      def provider_rows(inboxes)
        [row('gmail', inboxes.count { |inbox| mail?(inbox, Connections::Gmail) }, Connections::Gmail.allowed?(@account)),
         row('microsoft', inboxes.count { |inbox| mail?(inbox, Connections::Microsoft) }, Connections::Microsoft.allowed?(@account)),
         row('line', inboxes.count { |inbox| line_configured?(inbox) }, true),
         row('web_widget', inboxes.count { |inbox| inbox.channel_type == 'Channel::WebWidget' }, feature?('channel_website')),
         row('instagram', inboxes.count { |inbox| inbox.channel_type == 'Channel::Instagram' }, instagram_available?)]
      end

      # 準備中(preparing)は、審査・公開判定・アプリ設定が揃っていない窓口。押しても接続できないため選ばせない。
      def row(key, count, available)
        { 'key' => key, 'state' => state(count, available), 'count' => count }
      end

      def state(count, available)
        return 'connected' if count.positive?

        available ? 'available' : 'preparing'
      end

      def mail?(inbox, provider)
        inbox.channel_type == 'Channel::Email' && provider.connected?(inbox.channel)
      end

      def line_configured?(inbox)
        return false unless inbox.channel_type == 'Channel::Line'

        channel = inbox.channel
        channel.line_channel_id.present? && channel.line_channel_secret.present? && channel.line_channel_token.present?
      end

      def feature?(name)
        @account.respond_to?(:feature_enabled?) && @account.feature_enabled?(name)
      end

      # Chatwoot の受信箱追加画面と同じ条件(Instagram の機能と、Meta アプリの設定)。
      def instagram_available?
        feature?('channel_instagram') && GlobalConfigService.load('INSTAGRAM_APP_ID', nil).present?
      end
    end
  end
end
