# frozen_string_literal: true

class Api::V1::Widget::SessionsController < Api::V1::Widget::BaseController
  include Toybaco::WidgetPrivacyResponse

  def destroy
    Toybaco::Security::WidgetSession.revoke(@contact_inbox, source_id: auth_token_params[:source_id]) if @contact_inbox
    render json: { session_revoked: true }
  end

  private

  def set_contact
    return if auth_token_params.blank?

    raise ActiveRecord::RecordNotFound unless auth_token_params[:inbox_id] == @web_widget.inbox.id

    @contact_inbox = @web_widget.inbox.contact_inboxes.find_by(source_id: auth_token_params[:source_id])
  end
end
