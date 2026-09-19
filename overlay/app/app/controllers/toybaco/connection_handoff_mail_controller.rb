# frozen_string_literal: true

require_relative 'connection_handoff_sessions_controller'
require_relative '../../../lib/toybaco/connections/handoff/mail_setup'
require_relative '../../../lib/toybaco/connections/handoff/mail_oauth_state'

class Toybaco::ConnectionHandoffMailController < Toybaco::ConnectionHandoffSessionsController
  skip_before_action :load_record, only: :callback
  skip_before_action :same_origin_json, only: :callback
  before_action :bind_callback, only: :callback
  rescue_from Toybaco::Connections::GmailApi::Error, Toybaco::Connections::MicrosoftApi::Error,
              ActiveRecord::ActiveRecordError, IOError, Timeout::Error, SocketError, KeyError, ArgumentError,
              ActionController::ParameterMissing, OpenSSL::SSL::SSLError, with: :mail_unavailable

  def show
    @record.account.with_lock do
      @record.with_lock do
        Handoff::Access.receipt!(@record, required_nonce)
        render json: Handoff::Presentation.recipient(@record).merge(mail_available: gateway.allowed?(@record.account))
      end
    end
  end

  def create
    @record.account.with_lock do
      @record.with_lock do
        Handoff::Access.claim!(@record, required_nonce)
        raise Handoff::Unavailable unless gateway.allowed?(@record.account)

        saved = state.issue(public_id: @record.public_id, provider: @record.provider, browser_nonce: required_nonce,
                            application: gateway.binding, expires_at: @record.expires_at)
        render json: { url: gateway.authorization_url(state: saved.fetch('state'), challenge: saved.fetch('challenge')) }
      end
    end
  end

  def callback
    return return_with('cancelled') if params[:error].present?
    raise Handoff::Unavailable unless gateway.allowed?(@record.account)

    gateway.enqueue(connect_inbox)
    return_with('connected')
  end

  private

  def connect_inbox
    code = params[:code]
    raise Handoff::Invalid unless code.is_a?(String) && code.bytesize.between?(1, 8192)

    payload = gateway.exchange(code: code, verifier: @saved.fetch('verifier'))
    raise Handoff::Forbidden unless Handoff::Access.equal?(@saved.fetch('application'), gateway.binding)

    Handoff::MailSetup.new(@record, gateway: gateway).save!(browser_nonce: required_nonce, payload: payload)
  end

  def gateway
    @gateway ||= Handoff::MailGateway.new(@record.provider)
  end

  def state
    Handoff::MailOauthState.new(store: Redis::Alfred)
  end

  def bind_callback
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
    @record = callback_record

    Handoff::Access.claim!(@record, required_nonce)
    @saved = state.consume(params[:state], public_id: @record.public_id, provider: @record.provider,
                                           browser_nonce: required_nonce, application: gateway.binding)
    raise Handoff::Forbidden unless @saved
  end

  def callback_record
    cookie = cookies.encrypted[COOKIE]
    raise Handoff::Forbidden unless cookie.is_a?(Hash) && cookie['id'].to_s.match?(Handoff::Access::UUID)

    record = Toybaco::ConnectionHandoff.find_by(public_id: cookie['id'])
    raise Handoff::Forbidden unless record && params[:provider] == record.provider

    record
  end

  def return_with(result)
    redirect_to "/toybaco/connections/help/#{@record.public_id}?mail=#{result}", allow_other_host: false
  end

  def mail_unavailable(_error = nil)
    return return_with('retry') if action_name == 'callback' && @saved

    render json: { error: 'メールに接続できませんでした。もう一度お試しください。' }, status: :service_unavailable
  end
end
