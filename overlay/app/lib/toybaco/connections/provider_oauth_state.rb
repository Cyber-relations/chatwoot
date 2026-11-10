# frozen_string_literal: true

require 'securerandom'
require_relative 'oauth_state'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    # Upstream Instagram, TikTok, Linear and Shopify connections carry the store in an HS256 token {sub, iat} with no exp:
    # it never expires, can be replayed with a new provider code, and the callback checks no session. Shopify's start had
    # no role check. These connections use the Gmail/Microsoft state instead (OauthState): a one-use Redis nonce for 15
    # minutes that holds the store, the starting user and the provider, bound to the starting browser's cookie. The
    # callback consumes it before the store is chosen; the store comes only from the consumed state.
    module ProviderOauthState
      BROWSER_COOKIE = :toybaco_connection_browser

      # Account API starts. API tokens alone cannot start a browser connection (as GoogleAuthorization).
      module Start
        private

        def toybaco_connection_session?
          session_user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
          session_user.present? && session_user == Current.user
        end

        def toybaco_connection_state(provider, return_to: 'settings', account: Current.account, user: Current.user)
          response.headers['Cache-Control'] = 'no-store'
          OauthState.new(store: Redis::Alfred).issue(account_id: account.id, user_id: user.id,
                                                     browser_nonce: toybaco_connection_browser_nonce, provider: provider,
                                                     return_to: return_to).fetch('state')
        end

        # The same encrypted cookie as the Gmail and Microsoft starts.
        def toybaco_connection_browser_nonce
          browser_nonce = cookies.encrypted[BROWSER_COOKIE]
          browser_nonce = SecureRandom.hex(32) unless browser_nonce.to_s.match?(/\A[0-9a-f]{64}\z/)
          cookies.encrypted[BROWSER_COOKIE] = { value: browser_nonce, httponly: true, secure: request.ssl?, same_site: :lax,
                                                expires: 15.minutes.from_now, path: '/' }
          browser_nonce
        end
      end

      # POST /api/v1/accounts/:account_id/instagram/authorization (administrators, OauthAuthorizationController).
      module InstagramStart
        include Start

        def create
          return head :unauthorized unless toybaco_connection_session?

          super
        end

        private

        def generate_instagram_token(_account_id, return_to = nil)
          toybaco_connection_state('instagram', return_to: return_to == 'onboarding' ? 'onboarding' : 'settings')
        end
      end

      # POST /api/v1/accounts/:account_id/tiktok/authorization (administrators, OauthAuthorizationController).
      module TiktokStart
        include Start

        def create
          return head :unauthorized unless toybaco_connection_session?

          super
        end

        private

        def generate_tiktok_token(_account_id, return_to = nil)
          toybaco_connection_state('tiktok', return_to: return_to == 'onboarding' ? 'onboarding' : 'settings')
        end
      end

      # Integrations::App. Upstream renders the Linear authorize URL (with its state) into the integrations JSON when the page
      # loads, and the page opens it as a plain link later. The JSON links the connect button to the Toybaco start instead
      # (Toybaco::LinearStartController), which issues a fresh state when the button is pressed and redirects to Linear.
      module LinearAppState
        START_PATH = '/toybaco/connections/linear/start'

        attr_accessor :toybaco_connection_state

        def action
          return super unless id == 'linear' && toybaco_connection_state.nil? && Current.account

          "#{START_PATH}?#{{ account_id: Current.account.id }.to_query}"
        end

        def encode_state
          toybaco_connection_state
        end
      end

      # POST /api/v1/accounts/:account_id/integrations/shopify/auth. Upstream lets any store user start it and accepts
      # any shop_domain as the host of the returned URL.
      module ShopifyStart
        include Start

        SHOP_DOMAIN_ERROR = 'Shopify のストアのアドレスは ○○.myshopify.com の形で入力してください。'

        def auth
          raise ::Pundit::NotAuthorizedError unless Current.account_user&.administrator?
          return head :unauthorized unless toybaco_connection_session?
          return super if params[:shop_domain].blank?

          shop = ::Shopify::ShopDomain.normalize(params[:shop_domain])
          # The callback accepts only *.myshopify.com (Toybaco::Security::ShopifyCallbackDomain); start with the same rule.
          return render json: { error: SHOP_DOMAIN_ERROR }, status: :unprocessable_entity unless toybaco_shop_domain?(shop)

          params[:shop_domain] = shop
          super
        end

        private

        def toybaco_shop_domain?(shop)
          ::Shopify::ShopDomain.valid?(shop) && shop.end_with?('.myshopify.com')
        end

        def generate_shopify_token(_account_id)
          toybaco_connection_state('shopify')
        end
      end

      # The provider callbacks (GET /<provider>/callback). Same answers as the Gmail and Microsoft callbacks: no
      # dashboard sign-in 401, a state that is not this browser's and user's, unused and unexpired 400, a starter who is
      # no longer an administrator of the store, or a suspended store, 403. Nothing reaches the provider before this.
      module Callback
        def show
          toybaco_bind_connection
          super unless performed?
        end

        private

        def toybaco_bind_connection
          response.headers['Cache-Control'] = 'no-store'
          response.headers['Referrer-Policy'] = 'no-referrer'
          user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
          return head :unauthorized unless user

          @toybaco_connection = toybaco_consume_connection(user)
          return head :bad_request unless @toybaco_connection

          membership = toybaco_connection_membership(user)
          return head :forbidden unless membership

          @toybaco_connection_account = membership.account
        end

        # The store of the consumed state, while the user is its administrator and it is not suspended (the account API
        # starts check suspension, but a store can be suspended during the authorization).
        def toybaco_connection_membership(user)
          membership = user.account_users.find_by(account_id: @toybaco_connection.fetch('account_id'))
          membership if membership&.administrator? && membership.account.active?
        end

        def toybaco_consume_connection(user)
          states = OauthState.new(store: Redis::Alfred)
          states.consume(params[:state], user_id: user.id, browser_nonce: cookies.encrypted[BROWSER_COOKIE], provider: toybaco_connection_provider)
        end

        def toybaco_connection_account_id
          @toybaco_connection_account&.id
        end

        def toybaco_connection_return_to
          @toybaco_connection&.fetch('return_to')
        end
      end

      module InstagramCallback
        include Callback

        private

        def toybaco_connection_provider
          'instagram'
        end

        def account_id
          toybaco_connection_account_id
        end

        def return_to
          toybaco_connection_return_to
        end
      end

      module TiktokCallback
        include Callback

        private

        def toybaco_connection_provider
          'tiktok'
        end

        def account_id
          toybaco_connection_account_id
        end

        def return_to
          toybaco_connection_return_to
        end
      end

      # Reconnecting Linear still replaces the store's token (upstream), but only from a fresh state of an administrator.
      module LinearCallback
        include Callback

        private

        def toybaco_connection_provider
          'linear'
        end

        def account_id
          toybaco_connection_account_id
        end
      end

      module ShopifyCallback
        include Callback

        private

        def toybaco_connection_provider
          'shopify'
        end

        def verify_account!
          @account_id = toybaco_connection_account_id
          @account = @toybaco_connection_account
        end

        def account_id
          toybaco_connection_account_id
        end
      end
    end
  end
end
