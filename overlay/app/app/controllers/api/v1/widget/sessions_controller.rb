# frozen_string_literal: true

class Api::V1::Widget::SessionsController < Api::V1::Widget::BaseController
  include Toybaco::WidgetPrivacyResponse

  def destroy
    if @toybaco_http_session && request.headers['X-Auth-Token'].to_s.start_with?('tbwp1.', 'tbwr1.')
      @toybaco_http_session.revoke!(request.headers['X-Auth-Token'], @web_widget)
    elsif @contact_inbox
      Toybaco::Security::WidgetSession.revoke(@contact_inbox, source_id: auth_token_params[:source_id])
    end
    cookies.delete(Toybaco::Security::WidgetHttpSession.cookie_name(@web_widget, secure: request.ssl?),
                   path: '/', secure: request.ssl?, httponly: true, same_site: request.ssl? ? :none : :lax, partitioned: request.ssl?)
    render json: { session_revoked: true }
  end

  private

  def set_contact
    return if auth_token_params.blank?

    raise ActiveRecord::RecordNotFound unless auth_token_params[:inbox_id] == @web_widget.inbox.id

    @contact_inbox = @web_widget.inbox.contact_inboxes.find_by(source_id: auth_token_params[:source_id])
  end
end
