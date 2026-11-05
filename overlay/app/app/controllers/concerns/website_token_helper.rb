module WebsiteTokenHelper
  def auth_token_params
    return @auth_token_params if defined?(@auth_token_params)

    token = request.headers['X-Auth-Token'].to_s
    @toybaco_http_authenticated = token.start_with?('tbwp1.', 'tbwr1.')
    @toybaco_http_session = if token.start_with?('tbwr1.')
                              Toybaco::Security::WidgetHttpSession.read_for_recovery(request, @web_widget)
                            else
                              Toybaco::Security::WidgetHttpSession.read(request, @web_widget)
                            end
    @auth_token_params = if token.start_with?('tbwr1.')
                           recovery_auth_token_params(token)
                         elsif token.start_with?('tbwp1.')
                           proof_auth_token_params(token)
                         else
                           raise ActiveRecord::RecordNotFound
                         end
  end

  def set_web_widget
    @web_widget = ::Channel::WebWidget.find_by!(website_token: permitted_params[:website_token])
    @current_account = @web_widget.inbox.account

    raise ActiveRecord::RecordNotFound unless @current_account.active?
  end

  def set_contact
    raise ActiveRecord::RecordNotFound unless auth_token_params[:inbox_id] == @web_widget.inbox.id

    @contact_inbox = @web_widget.inbox.contact_inboxes.find_by(
      source_id: auth_token_params[:source_id]
    )
    @contact = @contact_inbox&.contact
    raise ActiveRecord::RecordNotFound unless @contact

    Current.contact = @contact
  end

  def permitted_params
    params.permit(:website_token)
  end

  private

  def recovery_auth_token_params(token)
    recovery = Toybaco::Security::WidgetHttpSession.recovery(token, @web_widget)
    raise ActiveRecord::RecordNotFound unless Toybaco::Security::WidgetHttpSession.same_origin?(request)
    raise ActiveRecord::RecordNotFound if @toybaco_http_session &&
                                          @toybaco_http_session.record.contact_inbox_id != recovery.record.contact_inbox_id

    @toybaco_http_session = recovery
    recovery.claims
  end

  def proof_auth_token_params(token)
    raise Toybaco::Security::WidgetHttpSession::ExpiredProof if expired_http_proof?(token)
    raise ActiveRecord::RecordNotFound unless @toybaco_http_session &&
                                              Toybaco::Security::WidgetHttpSession.same_origin?(request) &&
                                              @toybaco_http_session.valid_proof?(token)

    @toybaco_http_session.claims
  end

  def expired_http_proof?(token)
    @toybaco_http_session && Toybaco::Security::WidgetHttpSession.same_origin?(request) &&
      @toybaco_http_session.valid_proof?(token, allow_expired: true) && !@toybaco_http_session.valid_proof?(token)
  end
end
