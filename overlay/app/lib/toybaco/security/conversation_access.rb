# frozen_string_literal: true

module Toybaco::Security::ConversationAccess
  module CaptainTasks
    private

    def check_authorization
      super
      return if params[:conversation_display_id].blank?

      conversation = Current.account.conversations.find_by!(display_id: params[:conversation_display_id])
      authorize conversation, :show?
    end
  end

  module Linear
    def unlink_issue
      processor = linear_processor_service
      links = processor.linked_issues(conversation_link)
      return render json: { error: links[:error] }, status: :unprocessable_entity if links[:error]

      link = find_linked_issue(links[:data])
      result = processor.unlink_issue(link.fetch('id'))
      return render json: { error: result[:error] }, status: :unprocessable_entity if result[:error]

      ::Linear::ActivityMessageService.new(
        conversation: @conversation, action_type: :issue_unlinked,
        issue_data: { id: link.fetch('issue').fetch('identifier') }, user: Current.user
      ).perform
      render json: result[:data], status: :ok
    end

    private

    def find_linked_issue(links)
      link = Array(links).find do |candidate|
        candidate.is_a?(Hash) && candidate['id'].present? && candidate['id'] == permitted_params[:link_id]
      end
      raise ActiveRecord::RecordNotFound unless link && link.dig('issue', 'identifier').present?

      link
    end

    def fetch_conversation
      super
      authorize @conversation, :show?
    end
  end

  # This controller inherits from ActiveStorage, not ApplicationController.
  # Supply the same Pundit context for both session and access-token callers.
  module DirectUploads
    private

    def conversation
      @conversation = Current.account.conversations.find_by!(display_id: params[:conversation_id])
      Pundit.authorize(
        { user: current_user || Current.user, account: Current.account, account_user: Current.account_user },
        @conversation, :show?
      )
      @conversation
    end
  end
end
