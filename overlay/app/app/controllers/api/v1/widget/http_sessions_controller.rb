# frozen_string_literal: true

class Api::V1::Widget::HttpSessionsController < ApplicationController
  include Toybaco::WidgetPrivacyResponse
  before_action :set_widget
  before_action :require_same_origin
  rescue_from ActiveRecord::RecordNotFound, with: :not_found
  rescue_from Toybaco::Security::WidgetHttpSession::Conflict do
    render json: { error: 'widget_session_conflict' }, status: :conflict
  end
  rescue_from Toybaco::Security::WidgetHttpSession::RetryIntent do
    render json: { error: 'widget_session_retry' }, status: :conflict
  end

  def show
    with_authenticated(cookie_only: true) do |session|
      session.mark_persisted!
      render json: { persisted: true, proof: session.proof }
    end
  end

  def create
    return create_ephemeral if params[:ephemeral] == true

    session, secret = Toybaco::Security::WidgetHttpSession.bootstrap(
      request, @web_widget, legacy_token: params[:legacy_token], intent: params[:consume_intent]
    )
    session.issue_cookie(request, @web_widget, secret)
    render json: { proof: session.proof, issued: true, recovery_code: session.handoff(kind: 'recovery') }
  end

  def proof
    with_authenticated(allow_expired: true) do |session|
      render json: { proof: session.proof }
    end
  end

  def handoff
    # Acquire the cutover lock before with_authenticated takes session/link locks.
    Toybaco::Security::WidgetSessionSecurityEpoch.with_creation_lock do
      with_authenticated { |session| render json: { code: session.handoff } }
    end
  end

  def consume
    session, secret = Toybaco::Security::WidgetHttpSession.consume(
      request, @web_widget, code: params[:handoff_code], intent: params[:consume_intent]
    )
    session.issue_cookie(request, @web_widget, secret)
    render json: { proof: session.proof, issued: true, recovery_code: session.handoff(kind: 'recovery') }
  end

  def recover
    _session, token = Toybaco::Security::WidgetHttpSession.recover(
      request, @web_widget, code: params[:handoff_code], intent: params[:consume_intent]
    )
    render json: { proof: token, persisted: false }
  end

  def destroy
    Toybaco::Security::WidgetHttpSession.discard_cookie(request, @web_widget)
    render json: { cookie_session_revoked: true }
  end

  private

  def create_ephemeral
    proof = Toybaco::Security::WidgetHttpSession.bootstrap_ephemeral(request, @web_widget, intent: params[:consume_intent])
    render json: { proof: proof, persisted: false }
  end

  def set_widget
    @web_widget = Channel::WebWidget.find_by!(website_token: params[:website_token])
    raise ActiveRecord::RecordNotFound unless @web_widget.inbox.account.active?
  end

  def require_same_origin
    raise ActiveRecord::RecordNotFound unless Toybaco::Security::WidgetHttpSession.same_origin?(request)
  end

  def authenticated(allow_expired: false, cookie_only: false)
    token = request.headers['X-Auth-Token'].to_s
    return authenticated_recovery(token) if !cookie_only && !allow_expired && token.start_with?('tbwr1.')

    session = Toybaco::Security::WidgetHttpSession.read(request, @web_widget)
    raise ActiveRecord::RecordNotFound unless session&.valid_proof?(token, allow_expired: allow_expired)

    session
  end

  def with_authenticated(allow_expired: false, cookie_only: false)
    session = authenticated(allow_expired: allow_expired, cookie_only: cookie_only)
    session.record.with_lock do
      session.record.contact_inbox.with_lock do
        # Waiting for the lock may cross a reset or setUser. Recheck the
        # original request proof before persisting or issuing any capability.
        yield authenticated(allow_expired: allow_expired, cookie_only: cookie_only)
      end
    end
  end

  def authenticated_recovery(token)
    recovery = Toybaco::Security::WidgetHttpSession.recovery(token, @web_widget)
    cookie = Toybaco::Security::WidgetHttpSession.read_for_recovery(request, @web_widget)
    raise ActiveRecord::RecordNotFound if cookie && cookie.record.contact_inbox_id != recovery.record.contact_inbox_id

    recovery
  end

  def not_found
    render json: { error: 'Widget session unavailable' }, status: :not_found
  end
end
