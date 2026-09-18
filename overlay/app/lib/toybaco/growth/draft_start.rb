# frozen_string_literal: true

require_relative 'ai_ledger'
require_relative 'draft_access'
require_relative 'draft_input'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class DraftStart
      class Unavailable < StandardError; end

      def initialize(account, conversation, user)
        @account = account
        @conversation = conversation
        @user = user
      end

      def create!(nonce:, draft:)
        raise ArgumentError, 'invalid generation nonce' unless nonce.is_a?(String) && nonce.match?(/\A[0-9a-f-]{36}\z/)

        @account.with_lock do
          @conversation.with_lock do
            raise Unavailable, '現在、この会話ではAIを利用できません。' unless DraftAccess.enabled? && DraftAccess.allowed?(@account, @user, @conversation)

            input = DraftInput.new(@account, @conversation, @user)
            payload = input.build(draft)
            allocate!(input.digest(payload), payload, nonce)
          end
        end
      end

      private

      def requests
        Toybaco::GrowthDraftRequest.where(account_id: @account.id, user_id: @user.id, conversation_id: @conversation.id)
      end

      def allocate!(digest, input, nonce)
        pending = requests.where(state: %w[queued running]).where('expires_at > ?', Time.now.utc).first
        if pending
          raise Unavailable, '前の下書きを作成中です。少し待ってからお試しください。' unless pending.operation.context_digest == digest

          return pending
        end

        key = Digest::SHA256.hexdigest("manual-reply:#{@user.id}:#{nonce}")
        reservation = AiLedger.new(@account).reserve(request_key: key, kind: 'reply_draft', context_digest: digest)
        return requests.find_by!(operation_id: reservation['operation_id']) if reservation['result'] == 'duplicate'
        raise Unavailable, '現在、利用できるAI枠がありません。' unless reservation['result'] == 'reserved'

        persist!(input, reservation)
      end

      def persist!(input, reservation)
        operation = Toybaco::GrowthAiOperation.find(reservation.fetch('operation_id'))
        request = requests.create!(operation: operation, incoming_id: input.fetch('incoming_id'), draft_digest: input.fetch('draft_digest'),
                                   public_tail_id: input.fetch('public_tail_id'), facts_revision: input.fetch('facts').fetch('revision'),
                                   expires_at: operation.lease_expires_at)
        request.update!(encrypted_input: DraftInput.encrypt(request, input.merge('token' => reservation.fetch('token'))))
        request
      end
    end
  end
end
