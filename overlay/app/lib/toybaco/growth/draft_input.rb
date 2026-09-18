# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'store_facts'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class DraftInput
      def initialize(account, conversation, user)
        @account = account
        @conversation = conversation
        @user = user
      end

      def build(draft)
        validate_draft!(draft)

        facts = StoreFacts.new(@account).read
        incoming = latest_incoming
        raise ArgumentError, 'store facts and customer question required' unless facts['confirmed'] && incoming&.content.present?

        { 'facts' => facts, 'incoming_id' => incoming.id, 'incoming_content' => incoming.content,
          'public_tail_id' => public_messages.maximum(:id),
          'draft' => draft, 'draft_digest' => Digest::SHA256.hexdigest(draft), 'user_id' => @user.id,
          'messages' => history }
      end

      def digest(input)
        Digest::SHA256.hexdigest(JSON.generate([input['incoming_id'], input['incoming_content'], input.dig('facts', 'revision'),
                                                input['draft_digest'], input['user_id']]))
      end

      def current?(input)
        incoming = latest_incoming
        facts = StoreFacts.new(@account).read
        question_matches?(incoming, input) && facts['confirmed'] && facts['revision'] == input.dig('facts', 'revision') &&
          @conversation.messages.where(private: false, message_type: %i[incoming outgoing]).maximum(:id) == input['public_tail_id']
      end

      def self.encrypt(request, input)
        encryptor.encrypt_and_sign(input, purpose: purpose(request))
      end

      def self.decrypt(request)
        encryptor.decrypt_and_verify(request.encrypted_input, purpose: purpose(request))
      end

      def self.encryptor
        key = Rails.application.key_generator.generate_key('toybaco-business-draft-v1', 32)
        ActiveSupport::MessageEncryptor.new(key, cipher: 'aes-256-gcm', serializer: JSON)
      end

      def self.purpose(request)
        "toybaco-draft:#{request.account_id}:#{request.user_id}:#{request.id}"
      end

      private

      def validate_draft!(draft)
        return if draft.is_a?(String) && draft.length <= 4000 && draft.exclude?("\u0000")

        raise ArgumentError, 'invalid draft input'
      end

      def public_messages
        @conversation.messages.where(private: false, message_type: %i[incoming outgoing])
      end

      def history
        remaining = 8000
        public_messages.order(id: :desc).limit(12).filter_map do |message|
          next if remaining.zero?

          content = message.content.to_s.first([4000, remaining].min)
          remaining -= content.length
          { 'role' => message.incoming? ? 'customer' : 'store', 'content' => content }
        end.reverse
      end

      def question_matches?(incoming, input)
        incoming&.id == input['incoming_id'] && incoming.content == input['incoming_content']
      end

      def latest_incoming
        @conversation.messages.where(private: false, message_type: :incoming).order(created_at: :desc, id: :desc).first
      end
    end
  end
end
