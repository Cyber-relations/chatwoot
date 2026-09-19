# frozen_string_literal: true

require_relative 'context'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Support
    class Diagnostics
      class Forbidden < StandardError; end
      CHECKS = {
        'first_steps' => %i[account_state inbox_presence facts_state],
        'connection' => %i[account_state inbox_presence mail_authorization],
        'line' => %i[account_state line_presence],
        'gmail' => %i[account_state inbox_presence mail_authorization],
        'microsoft' => %i[account_state inbox_presence mail_authorization],
        'reply' => %i[account_state inbox_presence],
        'facts' => %i[account_state facts_state],
        'ai' => %i[account_state facts_state],
        'billing' => %i[billing_permission]
      }.freeze

      def initialize(account, user)
        @account = account
        @user = user
        @context = Context.new(account, user)
      end

      def call(article_id)
        available = Knowledge.articles(@context).any? { |article| article['id'] == article_id }
        raise Forbidden unless available && CHECKS.key?(article_id)

        checks = CHECKS.fetch(article_id).map { |method| send(method) }
        { 'version' => Knowledge::VERSION, 'account_id' => @account.id, 'article_id' => article_id, 'checks' => checks }
      end

      private

      def row(id, state, text)
        { 'id' => id, 'state' => state, 'text' => text }
      end

      def account_state
        @account.active? ? row('account', 'ok', '店舗は利用可能な状態です。') : row('account', 'attention', '店舗は停止中です。契約者に確認してください。')
      end

      def inboxes
        @inboxes ||= begin
          scope = @account.inboxes.order(:id)
          scope = scope.joins(:inbox_members).where(inbox_members: { user_id: @user.id }) unless @context.administrator?
          scope
        end
      end

      def inbox_presence
        return row('inboxes', 'information', '利用できる受信箱が登録されています。実際の受信は受信箱で確認してください。') if inboxes.exists?

        row('inboxes', 'attention', '利用できる受信箱がありません。店舗の管理者に接続・担当者の設定を確認してください。')
      end

      def line_presence
        return row('line', 'information', 'LINEの受信箱が登録されています。届いたメッセージで受信を確認してください。') if inboxes.exists?(channel_type: 'Channel::Line')

        row('line', 'attention', 'LINEの受信箱はまだ登録されていません。接続設定から始めてください。')
      end

      def mail_authorization
        channels = inboxes.where(channel_type: 'Channel::Email').includes(:channel).limit(101).to_a
        return row('mail', 'unknown', 'メール設定は受信箱ごとに確認してください。') if channels.length > 100
        return row('mail', 'information', 'メールの受信箱はまだ登録されていません。') if channels.empty?
        return row('mail', 'attention', '再認証が必要なメールがあります。受信箱の接続設定を確認してください。') if channels.any? { |inbox| inbox.channel.reauthorization_required? }

        row('mail', 'information', '再認証待ちの記録はありません。送受信が成功しているかは受信箱で確認してください。')
      end

      def facts_state
        return row('facts', 'information', 'お店情報は確認済みです。現在の営業内容と合っているかも確認してください。') if Growth::StoreFacts.new(@account).read['confirmed']

        row('facts', 'attention', 'お店情報が未確認です。初回案内で内容を確認してください。')
      end

      def billing_permission
        permissions = BillingAccess.permissions(@account, @user)
        return row('billing', 'ok', 'この利用者は契約の確認と変更ができます。') if permissions[:can_manage_billing]

        row('billing', 'information', 'この利用者は契約を確認できます。変更には店舗の管理者権限が必要です。')
      end
    end
  end
end
