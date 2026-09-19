# frozen_string_literal: true

require_relative 'ai_ledger'
require_relative 'post_draft_input'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class PostDraftStart
      class Unavailable < StandardError; end

      def initialize(account, user, organization_id:, editor_id:)
        @account = account
        @user = user
        @organization_id = organization_id
        @editor_id = editor_id
      end

      def create!(nonce:, draft:, instruction:)
        raise ArgumentError, 'invalid nonce' unless nonce.is_a?(String) && nonce.match?(PostDraftInput::UUID)

        @account.with_lock do
          allowed = DraftAccess.enabled? && PostDraftAccess.allowed?(@account, @user, @organization_id)
          raise Unavailable, '現在、この店舗では投稿AIを利用できません。' unless allowed

          input = PostDraftInput.build(@account, @user, organization_id: @organization_id, editor_id: @editor_id,
                                                        content: { draft: draft, instruction: instruction })
          allocate!(input, nonce)
        end
      end

      private

      def requests
        Toybaco::GrowthPostDraft.where(account_id: @account.id, user_id: @user.id, organization_id: @organization_id, editor_id: @editor_id)
      end

      def allocate!(input, nonce)
        digest = PostDraftInput.digest(input)
        pending = requests.where(state: %w[queued running]).where('expires_at > ?', Time.now.utc).first
        return reuse!(pending, digest) if pending

        key = Digest::SHA256.hexdigest("manual-post:#{@user.id}:#{@editor_id}:#{nonce}")
        reservation = AiLedger.new(@account).reserve(request_key: key, kind: 'post_draft', context_digest: digest)
        return requests.find_by!(operation_id: reservation['operation_id']) if reservation['result'] == 'duplicate'
        raise Unavailable, '現在、利用できるAI枠がありません。' unless reservation['result'] == 'reserved'

        persist!(input, reservation)
      end

      def reuse!(pending, digest)
        raise Unavailable, '前の投稿案を作成中です。少し待ってからお試しください。' unless pending.operation.context_digest == digest

        pending
      end

      def persist!(input, reservation)
        operation = Toybaco::GrowthAiOperation.find(reservation.fetch('operation_id'))
        request = requests.create!(operation: operation, draft_digest: input.fetch('draft_digest'), facts_revision: input.dig('facts', 'revision'),
                                   expires_at: operation.lease_expires_at)
        request.update!(encrypted_input: PostDraftInput.encrypt(request, input.merge('token' => reservation.fetch('token'))))
        request
      end
    end
  end
end
