# frozen_string_literal: true

require_relative '../entitlements'
require_relative '../connections/gmail'
require_relative '../connections/microsoft'
require_relative '../connections/handoff/line_setup'
require_relative '../connections/handoff/mail_gateway'
require_relative 'store_facts'
require_relative 'onboarding_inboxes'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class Onboarding
      VERSION = GrowthTerms::VERSION
      PREFERENCES = 'toybaco_guides'

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
        state = progress(chosen)
        state.merge('version' => VERSION, 'account_id' => @account.id, 'administrator' => administrator?, 'preference' => preference,
                    'facts' => StoreFacts.new(@account).read,
                    'gmail_available' => Connections::Gmail.allowed?(@account),
                    'microsoft_available' => Connections::Microsoft.allowed?(@account),
                    'handoff_line_available' => administrator? && Connections::Handoff::LineSetup.available?,
                    'handoff_mail_available' => handoff_mail_providers,
                    'inboxes' => mailboxes.map { |inbox| guide_inboxes.describe(inbox) })
      end

      def update!(attributes)
        raise ArgumentError, 'invalid guide preference' unless valid_preference?(attributes)

        @user.with_lock do
          attrs = @user.custom_attributes || {}
          guides = attrs[PREFERENCES] || {}
          saved = preference.merge(attributes).merge('version' => VERSION)
          @user.update!(custom_attributes: attrs.merge(PREFERENCES => guides.merge(@account.id.to_s => saved)))
        end
        read
      end

      private

      def handoff_mail_providers
        return [] unless administrator? && Connections::Handoff::Access.enabled?

        Connections::Handoff::MailGateway::PROVIDERS.select { |provider| Connections::Handoff::MailGateway.new(provider).allowed?(@account) }
      end

      def preference
        saved = @user.custom_attributes&.dig(PREFERENCES, @account.id.to_s)
        saved.is_a?(Hash) && saved['version'] == VERSION ? saved.slice('purpose', 'inbox_id', 'dismissed') : {}
      end

      def valid_preference?(attributes)
        return false unless (attributes.keys - %w[purpose inbox_id dismissed]).empty?
        return false unless optional_value?(attributes, 'purpose', %w[inbox posting]) && optional_value?(attributes, 'dismissed', [true, false])

        !attributes.key?('inbox_id') || guide_inboxes.visible.any? { |inbox| inbox.id == attributes['inbox_id'] }
      end

      def optional_value?(attributes, key, allowed)
        !attributes.key?(key) || allowed.include?(attributes[key])
      end

      def guide_inboxes
        OnboardingInboxes.new(@account, @user, administrator: administrator?)
      end

      def progress(inbox)
        return { 'phase' => 'purpose' } unless preference['purpose']
        return { 'phase' => 'posting' } if preference['purpose'] == 'posting'
        return { 'phase' => 'connect' } unless inbox
        return { 'phase' => 'facts', 'inbox_id' => inbox.id } unless StoreFacts.new(@account).read['confirmed']

        inbox_progress(inbox)
      end

      def inbox_progress(inbox)
        incoming = inbox.messages.where(message_type: :incoming, private: false).where.not(source_id: [nil, '']).order(:created_at, :id).first
        return { 'phase' => 'receive', 'inbox_id' => inbox.id } unless incoming

        # Chatwoot serializes this JSON column through ActiveRecord::Store.
        # Read the decoded receipt through the model rather than assuming a
        # particular SQL representation of content_attributes.
        replies = incoming.conversation.messages.where(message_type: :outgoing, private: false, sender_type: 'User')
                          .where('created_at >= ?', incoming.created_at)
        accepted = replies.select(:id, :source_id, :status, :content_attributes).find_each(batch_size: 100).any? do |reply|
          guide_inboxes.accepted_reply?(reply, inbox)
        end
        { 'phase' => accepted ? 'complete' : 'reply', 'inbox_id' => inbox.id, 'conversation_id' => incoming.conversation.display_id }
      end
    end
  end
end
