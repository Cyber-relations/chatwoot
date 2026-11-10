# frozen_string_literal: true

require_relative '../../../lib/toybaco/connections/provider_oauth_state'

# GET /toybaco/connections/linear/start?account_id=… — the Linear connect button of the integrations page links here
# (Toybaco::Connections::ProviderOauthState::LinearAppState). The page loads the link once, so the one-use 15-minute state
# is issued when the button is pressed, for the dashboard sign-in of an administrator of an active store, and bound to this
# browser like the other connection starts. Then the browser goes to Linear's authorize URL.
class Toybaco::LinearStartController < ActionController::Base # rubocop:disable Rails/ApplicationController
  include Toybaco::Connections::ProviderOauthState::Start

  ACCOUNT_ID = /\A[1-9][0-9]{0,17}\z/
  # A press in the dashboard is a same-origin navigation; browsers without Fetch Metadata send none.
  NAVIGATIONS = [nil, '', 'same-origin', 'none'].freeze

  before_action :bind_start

  def show
    @linear.toybaco_connection_state = toybaco_connection_state('linear', account: @membership.account, user: @user)
    redirect_to @linear.action, allow_other_host: true
  end

  private

  def bind_start
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
    return head :forbidden unless NAVIGATIONS.include?(request.headers['Sec-Fetch-Site'])

    @user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
    return head :unauthorized unless @user

    @membership = linear_membership(@user)
    return head :forbidden unless @membership

    @linear = Integrations::App.find(id: 'linear')
    head :not_found unless @linear&.active?(@membership.account)
  end

  # An administrator of a store that is not suspended (the account API checks suspension; this start is outside it).
  def linear_membership(user)
    return unless params[:account_id].is_a?(String) && params[:account_id].match?(ACCOUNT_ID)

    membership = user.account_users.find_by(account_id: params[:account_id])
    membership if membership&.administrator? && membership.account.active?
  end
end
