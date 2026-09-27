# frozen_string_literal: true

require_relative '../connections/gmail'
require_relative '../connections/microsoft'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class OnboardingInboxes
      # ガイドが「接続」「受信」「返信」で数える受信箱。Web チャットと Instagram は、メールの提供元の審査を待たずに
      # 店舗がつなげる窓口なので含める。開通時に作る転送用「メール」は Gmail・Microsoft の接続ではないため数えない(usable?)。
      TYPES = %w[Channel::Email Channel::Line Channel::WebWidget Channel::Instagram].freeze
      # 提供元の受理記録を持たない媒体。返信は、本人の返信(outgoing)が送信済み・配信済み・既読のどれかなら済みとする。
      OUTGOING_REPLY_TYPES = %w[Channel::WebWidget Channel::Instagram].freeze
      REPLIED_STATUSES = %w[sent delivered read].freeze
      LABELS = { 'line' => 'LINE公式', 'web_widget' => 'Webチャット', 'instagram' => 'Instagram' }.freeze

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

      # Web チャットは受信の確認でウィジェットを開くため、公開用の website_token を添える(サイトに貼る設置コードと同じ値)。
      def describe(inbox)
        channel = inbox.channel
        key = provider(channel)
        described = { 'id' => inbox.id, 'name' => inbox.name, 'email' => (channel.email if channel.is_a?(Channel::Email)),
                      'provider' => key, 'label' => LABELS.key?(key) ? "#{inbox.name} · #{LABELS[key]}" : channel.email }
        channel.is_a?(Channel::WebWidget) ? described.merge('website_token' => channel.website_token) : described
      end

      # 受信の確認に使う、お客さまからの最初のメッセージ。メール・LINE・Instagram は提供元のメッセージ ID(source_id)を
      # 持つ取り込みだけを数える。Web チャットは店舗のウィジェット(website_token)から届くメッセージで source_id を持たないので、
      # 送り手がお客さま(Contact)のものだけを数える(自動のメッセージを受信と取り違えない)。
      def first_incoming(inbox)
        messages = inbox.messages.where(message_type: :incoming, private: false)
        messages = if inbox.channel_type == 'Channel::WebWidget'
                     messages.where(sender_type: 'Contact')
                   else
                     messages.where.not(source_id: [nil, ''])
                   end
        messages.order(:created_at, :id).first
      end

      def accepted_reply?(reply, inbox)
        return false if reply.content_attributes['deleted']
        # The fixed native LINE sender sets delivered only after HTTP 200.
        # Its outgoing messages have no source_id; this is API acceptance, not
        # proof that the recipient read or received the message.
        return %w[delivered read].include?(reply.status) if inbox.channel_type == 'Channel::Line'
        # Web チャットと Instagram には提供元の受理記録が無い。本人の返信が送信済み・配信済み・既読なら返信済み
        # (送信失敗や、状態が未設定の返信は数えない)。
        return REPLIED_STATUSES.include?(reply.status) if OUTGOING_REPLY_TYPES.include?(inbox.channel_type)
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
        case channel
        when Channel::Line then 'line'
        when Channel::WebWidget then 'web_widget'
        when Channel::Instagram then 'instagram'
        else Connections::Gmail.connected?(channel) ? 'gmail' : 'microsoft'
        end
      end

      def usable?(channel)
        case channel
        when Channel::Line then line_configured?(channel)
        when Channel::WebWidget then channel.website_token.present?
        when Channel::Instagram then instagram_connected?(channel)
        else mail_usable?(channel)
        end
      end

      def mail_usable?(channel)
        return false if channel.reauthorization_required?
        return Connections::Gmail.allowed?(@account) if Connections::Gmail.connected?(channel)

        Connections::Microsoft.application_current?(channel) && Connections::Microsoft.allowed?(@account)
      end

      def line_configured?(channel)
        channel.line_channel_id.present? && channel.line_channel_secret.present? && channel.line_channel_token.present?
      end

      # Chatwoot が接続済みとして扱う Instagram: Meta のアカウント ID と保存済みのトークンがあり、再認可を求められていない。
      # access_token メソッドはトークン更新の HTTP を呼び得るので、保存値(暗号化時は暗号文)の有無だけを見る。
      def instagram_connected?(channel)
        channel.instagram_id.present? && channel.read_attribute_before_type_cast('access_token').present? &&
          !channel.reauthorization_required?
      end
    end
  end
end
