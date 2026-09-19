# frozen_string_literal: true

require_relative 'post_draft_result'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class PostDraftState
      def initialize(context)
        @context = context
      end

      def read(request = @context.selected)
        account = @context.account
        facts = StoreFacts.new(account).read
        { 'available' => DraftAccess.enabled? && facts['confirmed'], 'store_info_required' => !facts['confirmed'],
          'remaining' => AiLedger.new(account).summary.fetch('remaining'), 'result' => request && result(request) }
      end

      private

      def result(request)
        value = request.attributes.slice('id', 'state', 'editor_id', 'draft_digest', 'error_code')
        current = PostDraftInput.current?(@context.account, request)
        value['current'] = current
        return value unless request.state == 'completed' && current
        return value.merge('error_code' => 'expired') unless request.result_expires_at && request.result_expires_at > Time.now.utc

        value.merge(PostDraftInput.decrypt(request, kind: 'result'))
      rescue ActiveSupport::MessageEncryptor::InvalidMessage
        value.merge('error_code' => 'generation_unavailable')
      end
    end
  end
end
