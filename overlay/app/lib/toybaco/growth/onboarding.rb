# frozen_string_literal: true

require_relative '../entitlements'
require_relative '../connections/gmail'
require_relative 'store_facts'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class Onboarding
      VERSION = '2026-09-18.1'
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
        mailboxes = gmail_inboxes
        chosen = mailboxes.find { |inbox| inbox.id == preference['inbox_id'] } || (mailboxes.first if mailboxes.length == 1)
        state = progress(chosen)
        state.merge('version' => VERSION, 'account_id' => @account.id, 'administrator' => administrator?, 'preference' => preference,
                    'facts' => StoreFacts.new(@account).read,
                    'gmail_available' => Connections::Gmail.allowed?(@account),
                    'inboxes' => mailboxes.map { |inbox| { 'id' => inbox.id, 'name' => inbox.name, 'email' => inbox.channel.email } })
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

      def preference
        saved = @user.custom_attributes&.dig(PREFERENCES, @account.id.to_s)
        saved.is_a?(Hash) && saved['version'] == VERSION ? saved.slice('purpose', 'inbox_id', 'dismissed') : {}
      end

      def valid_preference?(attributes)
        return false unless (attributes.keys - %w[purpose inbox_id dismissed]).empty?
        return false unless optional_value?(attributes, 'purpose', %w[inbox posting]) && optional_value?(attributes, 'dismissed', [true, false])

        !attributes.key?('inbox_id') || gmail_inboxes.any? { |inbox| inbox.id == attributes['inbox_id'] }
      end

      def optional_value?(attributes, key, allowed)
        !attributes.key?(key) || allowed.include?(attributes[key])
      end

      def gmail_inboxes
        return [] unless Connections::Gmail.allowed?(@account)

        visible = @account.inboxes.where(channel_type: 'Channel::Email').includes(:channel)
        visible = visible.joins(:inbox_members).where(inbox_members: { user_id: @user.id }) unless administrator?
        visible.select { |inbox| Connections::Gmail.connected?(inbox.channel) && !inbox.channel.reauthorization_required? }
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
                          .where('created_at >= ?', incoming.created_at).where.not(source_id: [nil, ''])
        accepted = replies.select(:id, :content_attributes).find_each(batch_size: 100).any? { |reply| accepted_reply?(reply) }
        { 'phase' => accepted ? 'complete' : 'reply', 'inbox_id' => inbox.id, 'conversation_id' => incoming.conversation.display_id }
      end

      def accepted_reply?(reply)
        receipt = reply.content_attributes['toybaco_gmail_send']
        receipt.is_a?(Hash) && receipt['state'] == 'accepted' && receipt['provider_id'].present? && receipt['accepted_at'].present?
      end
    end
  end
end
