# frozen_string_literal: true

require_relative 'post_draft_result'
require_relative 'post_draft_prompt'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class PostDraftWork
      def initialize(request, model: PostDraftModel.new)
        @request = request
        @account = request.account
        @model = model
      end

      def perform
        input = claim!
        return unless input

        prompt = PostDraftPrompt.build(facts: input.fetch('facts').fetch('fields'), draft: input.fetch('draft'),
                                       instruction: input.fetch('instruction'))
        result = @model.generate(prompt)
        raise DraftModel::Unavailable unless PostDraftPrompt.urls_allowed?(result.fetch('content'), input)

        PostDraftResult.new(@request).complete!(input, result)
      rescue StandardError => e
        Rails.logger.warn("toybaco_post_draft_failed request=#{@request.id} class=#{e.class}")
        PostDraftResult.new(@request.reload).fail!('generation_unavailable')
      end

      private

      def claim!
        @account.with_lock do
          @request.with_lock do
            return unless @request.state == 'queued'
            return reject!('expired') if @request.expires_at <= Time.now.utc
            return reject!('context_changed') unless PostDraftInput.current?(@account, @request)

            input = PostDraftInput.decrypt(@request)
            @request.update!(state: 'running')
            input
          end
        end
      end

      def reject!(reason)
        PostDraftResult.new(@request).fail!(reason)
        nil
      end
    end
  end
end
