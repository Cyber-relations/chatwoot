# frozen_string_literal: true

require 'uri'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Security
    # CASA 5.1.1: the SAML start puts request values into hand-built URLs without encoding them.
    # - POST /api/v1/auth/saml_login interpolates params[:target] into /auth/saml?account_id=…&RelayState=…
    #   (enterprise/app/controllers/api/v1/auth_controller.rb:13-15), so a target can add parameters to the start.
    # - The OmniAuth setup interpolates the request's account_id into the assertion consumer service URL
    #   (enterprise/config/initializers/omniauth_saml.rb:9-11, 27), and Active Record reads "5&x=1" as store 5.
    module SamlRequestParams
      ACCOUNT_ID = /\A[1-9][0-9]{0,17}\z/
      # The relay state is only compared with 'mobile' (case-insensitively) after the IdP answers; anything else is web.
      def self.relay_state(target)
        target.is_a?(String) && target.casecmp?('mobile') ? 'mobile' : 'web'
      end

      module Login
        def saml_login
          return super unless saml_sso_enabled? && @account

          query = URI.encode_www_form(account_id: @account.id, RelayState: SamlRequestParams.relay_state(params[:target]))
          redirect_to "/auth/saml?#{query}", status: :temporary_redirect
        end
      end

      # Prepended to OmniAuth::Strategies::SAML (a gem class, not reloaded).
      module Setup
        def setup_phase
          account_id = ActionDispatch::Request.new(env).params['account_id'] || env['omniauth.params']&.dig('account_id')
          if account_id && !account_id.to_s.match?(ACCOUNT_ID)
            # The same as the upstream setup without a store id: no store's SAML settings are used.
            options[:idp_cert] = 'DUMMY'
            return
          end

          super
          return if options[:assertion_consumer_service_url].blank?

          base_url = GlobalConfigService.load('FRONTEND_URL', 'http://localhost:3000')
          options[:assertion_consumer_service_url] = "#{base_url}/omniauth/saml/callback?#{URI.encode_www_form(account_id: account_id)}"
        end
      end
    end
  end
end
