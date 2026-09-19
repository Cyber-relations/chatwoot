# frozen_string_literal: true

require_relative '../../../lib/toybaco/connections/microsoft'
require_relative '../../../lib/toybaco/connections/oauth_state'

class Toybaco::MicrosoftCallbackController < ActionController::Base # rubocop:disable Rails/ApplicationController
  before_action :bind_callback

  def show
    return return_with('cancelled') if params[:error].present?
    return return_with('unavailable') unless Toybaco::Connections::Microsoft.allowed?(@account)

    inbox = connect_inbox
    Toybaco::MicrosoftFetchJob.perform_later(inbox.channel_id)
    return_with('connected', inbox: inbox)
  rescue Toybaco::Connections::MicrosoftApi::Error, ActiveRecord::ActiveRecordError, IOError, Timeout::Error, SocketError,
         KeyError, ArgumentError, ActionController::ParameterMissing, OpenSSL::SSL::SSLError
    return_with('retry')
  end

  private

  def bind_callback
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
    user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
    return head :unauthorized unless user

    @saved = consume_state(user)
    return head :bad_request unless @saved

    membership = user.account_users.find_by(account_id: @saved.fetch('account_id'))
    return head :forbidden unless membership&.administrator?

    @account = membership.account
    @return_to = @saved.fetch('return_to')
  end

  def consume_state(user)
    Toybaco::Connections::OauthState.new(store: Redis::Alfred).consume(
      params[:state], user_id: user.id, browser_nonce: cookies.encrypted[:toybaco_connection_browser], provider: 'microsoft'
    )
  end

  def connect_inbox
    api = Toybaco::Connections::Microsoft.api
    tokens = Toybaco::Connections::Microsoft.authorization_api.exchange(code: params.require(:code), verifier: @saved.fetch('verifier'))
    profile = api.profile(access_token: tokens.fetch('access_token'))
    folder = api.inbox(access_token: tokens.fetch('access_token'))
    Toybaco::Connections::Microsoft.connect!(account: @account, tokens: tokens, profile: profile, folder: folder)
  end

  def return_with(result, inbox: nil)
    target = if @return_to == 'growth'
               "/app/accounts/#{@account.id}/toybaco/start"
             elsif @return_to == 'onboarding'
               "/app/accounts/#{@account.id}/onboarding/inbox-setup"
             elsif inbox
               "/app/accounts/#{@account.id}/settings/inboxes/#{inbox.id}"
             else
               "/app/accounts/#{@account.id}/settings/inboxes"
             end
    redirect_to "#{target}?toybaco_connection=#{result}", allow_other_host: false
  end
end
