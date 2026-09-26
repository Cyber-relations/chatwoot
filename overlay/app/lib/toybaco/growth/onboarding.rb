# frozen_string_literal: true

require_relative '../entitlements'
require_relative '../connections/gmail'
require_relative '../connections/microsoft'
require_relative '../connections/handoff/line_setup'
require_relative '../connections/handoff/mail_gateway'
require_relative 'store_facts'
require_relative 'onboarding_inboxes'
require_relative 'onboarding_connections'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class Onboarding
      VERSION = GrowthTerms::VERSION
      PREFERENCES = 'toybaco_guides'
      # 各段は「あとで設定する」で先へ進める(接続が 0 件でも進める)。投稿から始める店舗は
      # 店舗情報 → 投稿 → 接続の順にし、AI に必要な店舗情報へ接続を通らずに届くようにする。
      STEPS = {
        'inbox' => %w[purpose connect facts receive reply complete],
        'posting' => %w[purpose facts posting connect complete]
      }.freeze
      SKIPPABLE = %w[connect facts receive reply posting].freeze
      # skipped は「あとで設定する」にした段、opened は画面を開いて済ませた段(投稿画面を開いた投稿の段)。
      # どちらも段を先へ進めるが、完了画面で再開を案内するのは「あとで」にした段だけ。
      STEP_LISTS = %w[skipped opened].freeze
      PREFERENCE_KEYS = %w[purpose inbox_id dismissed skipped opened].freeze

      def initialize(account, user)
        @account = account
        @user = user
      end

      def enabled?
        self.class.available?(@account)
      end

      def self.available?(account)
        account.active? && Entitlements.for_account(account)&.dig('ai_meter') == GrowthTerms::METER
      rescue PlanCatalog::Invalid
        false
      end

      def administrator?
        @account.account_users.exists?(user_id: @user.id, role: :administrator)
      end

      def read
        mailboxes = guide_inboxes.visible
        chosen = mailboxes.find { |inbox| inbox.id == preference['inbox_id'] } || (mailboxes.first if mailboxes.length == 1)
        progress(chosen).merge('version' => VERSION, 'account_id' => @account.id, 'administrator' => administrator?,
                               'preference' => preference, 'inboxes' => mailboxes.map { |inbox| guide_inboxes.describe(inbox) })
                        .merge(setup_state(mailboxes)).merge(availability)
      end

      def update!(attributes)
        raise ArgumentError, 'invalid guide preference' unless valid_preference?(attributes)

        @user.with_lock do
          attrs = @user.custom_attributes || {}
          guides = attrs[PREFERENCES] || {}
          saved = preference.merge(attributes).merge('version' => VERSION)
          # 目的を変えたら、前の目的で「あとで設定する」にした段・開いて済ませた段は持ち越さない。
          STEP_LISTS.each { |key| saved[key] = [] if purpose_changed?(attributes) && !attributes.key?(key) }
          @user.update!(custom_attributes: attrs.merge(PREFERENCES => guides.merge(@account.id.to_s => saved)))
        end
        read
      end

      private

      def setup_state(mailboxes)
        { 'steps' => STEPS.fetch(preference['purpose'] || 'inbox'), 'facts' => StoreFacts.new(@account).read,
          'pending' => pending(mailboxes), 'connections' => OnboardingConnections.new(@account, @user, administrator: administrator?).read }
      end

      def availability
        { 'gmail_available' => Connections::Gmail.allowed?(@account), 'microsoft_available' => Connections::Microsoft.allowed?(@account),
          'handoff_line_available' => administrator? && Connections::Handoff::LineSetup.available?,
          'handoff_mail_available' => handoff_mail_providers }
      end

      def handoff_mail_providers
        return [] unless administrator? && Connections::Handoff::Access.enabled?

        Connections::Handoff::MailGateway::PROVIDERS.select { |provider| Connections::Handoff::MailGateway.new(provider).allowed?(@account) }
      end

      def preference
        saved = @user.custom_attributes&.dig(PREFERENCES, @account.id.to_s)
        saved.is_a?(Hash) && saved['version'] == VERSION ? saved.slice(*PREFERENCE_KEYS) : {}
      end

      def purpose_changed?(attributes)
        attributes.key?('purpose') && attributes['purpose'] != preference['purpose']
      end

      def valid_preference?(attributes)
        return false unless (attributes.keys - PREFERENCE_KEYS).empty? && valid_values?(attributes)

        !attributes.key?('inbox_id') || guide_inboxes.visible.any? { |inbox| inbox.id == attributes['inbox_id'] }
      end

      def valid_values?(attributes)
        optional_value?(attributes, 'purpose', %w[inbox posting]) && optional_value?(attributes, 'dismissed', [true, false]) &&
          STEP_LISTS.all? { |key| !attributes.key?(key) || valid_steps?(attributes[key]) }
      end

      def valid_steps?(value)
        value.is_a?(Array) && value.all? { |step| SKIPPABLE.include?(step) } && value.uniq.length == value.length
      end

      def optional_value?(attributes, key, allowed)
        !attributes.key?(key) || allowed.include?(attributes[key])
      end

      def guide_inboxes
        OnboardingInboxes.new(@account, @user, administrator: administrator?)
      end

      def skipped?(step)
        Array(preference['skipped']).include?(step)
      end

      def opened?(step)
        Array(preference['opened']).include?(step)
      end

      def facts_confirmed?
        StoreFacts.new(@account).read['confirmed']
      end

      # 完了画面に出す「まだの準備」。受信の確認・返信の練習は任意なので含めない。接続は、店舗にガイドで受信・返信まで
      # 案内できる受信箱(Gmail・Microsoft・LINE)が 1 件も無いとき。開通時に自動作成する転送用メールだけでは済みにしない。
      # 所属で絞った一覧(mailboxes)が空でも、店舗にあれば出さない(接続できるのは管理者だけで、スタッフの所属は管理者が決める)。
      # 上限の数え方(Connections::InboxLimit・接続一覧の件数)は転送用を含めたまま。
      def pending(mailboxes)
        [('facts' unless facts_confirmed?), ('connect' unless mailboxes.any? || guide_inboxes.any_in_store?)].compact
      end

      def progress(inbox)
        return { 'phase' => 'purpose' } unless preference['purpose']
        return posting_progress(inbox) if preference['purpose'] == 'posting'

        inquiry_progress(inbox)
      end

      def inquiry_progress(inbox)
        return { 'phase' => 'connect' } unless inbox || skipped?('connect')
        return { 'phase' => 'facts', 'inbox_id' => inbox&.id }.compact unless facts_confirmed? || skipped?('facts')
        return { 'phase' => 'complete', 'replied' => false } unless inbox

        inbox_progress(inbox)
      end

      def posting_progress(inbox)
        return { 'phase' => 'facts' } unless facts_confirmed? || skipped?('facts')
        return { 'phase' => 'posting' } unless skipped?('posting') || opened?('posting')
        return { 'phase' => 'connect' } unless inbox || skipped?('connect')

        { 'phase' => 'complete', 'replied' => false }
      end

      def inbox_progress(inbox)
        incoming = inbox.messages.where(message_type: :incoming, private: false).where.not(source_id: [nil, '']).order(:created_at, :id).first
        unless incoming
          return { 'phase' => 'complete', 'inbox_id' => inbox.id, 'replied' => false } if skipped?('receive')

          return { 'phase' => 'receive', 'inbox_id' => inbox.id }
        end

        state = { 'inbox_id' => inbox.id, 'conversation_id' => incoming.conversation.display_id }
        accepted = first_reply_accepted?(incoming, inbox)
        return state.merge('phase' => 'reply') unless accepted || skipped?('reply')

        state.merge('phase' => 'complete', 'replied' => accepted)
      end

      def first_reply_accepted?(incoming, inbox)
        # Chatwoot serializes this JSON column through ActiveRecord::Store.
        # Read the decoded receipt through the model rather than assuming a
        # particular SQL representation of content_attributes.
        replies = incoming.conversation.messages.where(message_type: :outgoing, private: false, sender_type: 'User')
                          .where('created_at >= ?', incoming.created_at)
        replies.select(:id, :source_id, :status, :content_attributes).find_each(batch_size: 100).any? do |reply|
          guide_inboxes.accepted_reply?(reply, inbox)
        end
      end
    end
  end
end
