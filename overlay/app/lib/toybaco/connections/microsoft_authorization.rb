# frozen_string_literal: true

require_relative 'microsoft'
require_relative 'oauth_state'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module MicrosoftAuthorization
      BROWSER_COOKIE = :toybaco_connection_browser

      def create
        available = Microsoft.allowed?(Current.account)
        return super unless available || existing_microsoft_connection? || params[:return_to] == 'growth'
        return render(json: { error: 'この連携は現在準備中です。' }, status: :service_unavailable) unless available

        # The OAuth callback binds to the same web session, not just a submitted
        # store ID. API tokens alone cannot initiate a browser connection.
        session_user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
        return head :unauthorized unless session_user&.id == Current.user.id

        state = microsoft_oauth_state
        response.headers['Cache-Control'] = 'no-store'
        url = Microsoft.authorization_api.authorization_url(state: state.fetch('state'), challenge: state.fetch('challenge'))
        render json: { success: true, url: url }
      end

      private

      def existing_microsoft_connection?
        return false if params[:email].blank?

        channel = Current.account.email_channels.where('LOWER(email) = ?', params[:email].to_s.downcase).first
        Microsoft.connected?(channel)
      end

      def microsoft_oauth_state
        OauthState.new(store: Redis::Alfred).issue(account_id: Current.account.id, user_id: Current.user.id,
                                                   browser_nonce: microsoft_browser_nonce, provider: 'microsoft',
                                                   return_to: OauthState::RETURNS.include?(params[:return_to]) ? params[:return_to] : 'settings')
      end

      def microsoft_browser_nonce
        browser_nonce = cookies.encrypted[BROWSER_COOKIE]
        browser_nonce = SecureRandom.hex(32) unless browser_nonce.to_s.match?(/\A[0-9a-f]{64}\z/)
        cookies.encrypted[BROWSER_COOKIE] = { value: browser_nonce, httponly: true, secure: request.ssl?, same_site: :lax,
                                              expires: 15.minutes.from_now, path: '/' }
        browser_nonce
      end
    end
  end
end
