# frozen_string_literal: true

require_relative 'draft_result'
require_relative 'draft_prompt'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class DraftWork
      def initialize(request, model: DraftModel.new)
        @request = request
        @account = request.account
        @model = model
      end

      def perform
        input = claim!
        return unless input

        prompt = DraftPrompt.build(facts: input.fetch('facts').fetch('fields'), messages: input.fetch('messages'), draft: input.fetch('draft'))
        result = @model.generate(prompt)
        raise DraftModel::Unavailable, 'invalid generated URL' unless DraftPrompt.urls_allowed?(result.fetch('content'),
                                                                                                input.fetch('facts').fetch('fields'))

        DraftResult.new(@request).complete!(input, result)
      rescue StandardError => e
        Rails.logger.warn("toybaco_draft_failed request=#{@request.id} class=#{e.class}")
        DraftResult.new(@request.reload).fail!('generation_unavailable')
      end

      private

      def claim!
        @account.with_lock do
          @request.with_lock do
            return unless @request.state == 'queued'

            input = DraftInput.decrypt(@request)
            return reject!('expired') if @request.expires_at <= Time.now.utc
            return reject!('conversation_changed') unless ready?(input)

            @request.update!(state: 'running', started_at: Time.now.utc)
            input
          end
        end
      end

      def reject!(reason)
        DraftResult.new(@request).fail!(reason)
        nil
      end

      def ready?(input)
        user = User.find_by(id: @request.user_id)
        conversation = @account.conversations.find_by(id: @request.conversation_id)
        conversation && input.is_a?(Hash) && DraftAccess.enabled? && DraftAccess.allowed?(@account, user, conversation) &&
          DraftInput.new(@account, conversation, user).current?(input)
      end
    end
  end
end
