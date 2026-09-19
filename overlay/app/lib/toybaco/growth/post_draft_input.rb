# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'store_facts'
require_relative 'post_draft_access'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module PostDraftInput
      UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

      module_function

      def build(account, user, organization_id:, editor_id:, content:)
        raise ArgumentError, 'invalid editor' unless editor_id.is_a?(String) && editor_id.match?(UUID)

        validate_content!(content)
        draft, instruction = content.values_at(:draft, :instruction)

        facts = StoreFacts.new(account).read
        raise ArgumentError, '先に店舗情報を確認してください。' unless facts['confirmed']

        { 'facts' => facts, 'user_id' => user.id, 'organization_id' => organization_id, 'editor_id' => editor_id,
          'draft' => draft, 'instruction' => instruction, 'draft_digest' => Digest::SHA256.hexdigest(draft) }
      end

      def validate_content!(content)
        raise ArgumentError, 'invalid draft' unless valid_text?(content[:draft], 4000) && valid_text?(content[:instruction], 1000)
        raise ArgumentError, '投稿したい内容を入力してください。' if content[:draft].strip.empty? && content[:instruction].strip.empty?
      end

      def valid_text?(text, limit)
        text.is_a?(String) && text.length <= limit && text.exclude?("\u0000")
      end

      def digest(input)
        Digest::SHA256.hexdigest(JSON.generate(input.slice('user_id', 'organization_id', 'editor_id', 'draft_digest', 'instruction')
                                                  .merge('facts_revision' => input.fetch('facts').fetch('revision'))))
      end

      def current?(account, request)
        facts = StoreFacts.new(account).read
        user = User.find_by(id: request.user_id)
        DraftAccess.enabled? && facts['confirmed'] && facts['revision'] == request.facts_revision &&
          PostDraftAccess.allowed?(account, user, request.organization_id)
      end

      def encrypt(request, payload, kind: 'input')
        encryptor.encrypt_and_sign(payload, purpose: purpose(request, kind))
      end

      def decrypt(request, kind: 'input')
        raw = kind == 'input' ? request.encrypted_input : request.encrypted_result
        payload = encryptor.decrypt_and_verify(raw, purpose: purpose(request, kind))
        raise ActiveSupport::MessageEncryptor::InvalidMessage unless payload.is_a?(Hash)

        payload
      end

      def encryptor
        key = Rails.application.key_generator.generate_key('toybaco-posting-draft-v1', 32)
        ActiveSupport::MessageEncryptor.new(key, cipher: 'aes-256-gcm', serializer: JSON)
      end

      def purpose(request, kind)
        "toybaco-post-draft:#{request.account_id}:#{request.user_id}:#{request.id}:#{kind}"
      end
    end
  end
end
