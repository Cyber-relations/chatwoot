# frozen_string_literal: true

require 'json'
require 'uri'
require_relative 'microsoft_transport'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    class MicrosoftAuthorizationApi
      GRAPH_SCOPES = %w[User.Read Mail.ReadWrite Mail.Send].freeze
      SCOPES = (GRAPH_SCOPES.map { |scope| "https://graph.microsoft.com/#{scope}" } + ['offline_access']).freeze
      AUTHORIZE_URL = 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize'
      TOKEN_URL = 'https://login.microsoftonline.com/common/oauth2/v2.0/token'

      def initialize(client_id:, client_secret:, redirect_uri:, transport: MicrosoftTransport.new)
        @client_id = client_id
        @client_secret = client_secret
        @redirect_uri = redirect_uri
        @transport = transport
      end

      def authorization_url(state:, challenge:)
        raise ArgumentError, 'Microsoft is not configured' if @client_id.to_s.empty? || @client_secret.to_s.empty?
        raise ArgumentError, 'invalid OAuth binding' unless state.to_s.match?(/\A[0-9a-f]{64}\z/) && challenge.to_s.match?(/\A[A-Za-z0-9_-]{43}\z/)

        params = { client_id: @client_id, redirect_uri: @redirect_uri, response_type: 'code', response_mode: 'query',
                   scope: SCOPES.join(' '), prompt: 'select_account', state: state, code_challenge: challenge, code_challenge_method: 'S256' }
        "#{AUTHORIZE_URL}?#{URI.encode_www_form(params)}"
      end

      def exchange(code:, verifier:)
        result = token(grant_type: 'authorization_code', code: code, code_verifier: verifier, redirect_uri: @redirect_uri)
        raise MicrosoftApi::Error.new(403, nil, 'insufficient_scope') if result['refresh_token'].to_s.empty?

        result
      end

      def refresh(refresh_token:)
        token(grant_type: 'refresh_token', refresh_token: refresh_token)
      end

      private

      def token(**parameters)
        form = parameters.merge(client_id: @client_id, client_secret: @client_secret, scope: SCOPES.join(' '))
        response = @transport.call(method: :post, url: TOKEN_URL, headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                                   body: URI.encode_www_form(form))
        data = JSON.parse(response.fetch(:body), allow_duplicate_key: false)
        raise MicrosoftApi::Error.new(response[:status], nil, safe_reason(data)) unless response[:status] == 200

        validate_tokens!(data)
        data
      rescue JSON::ParserError, TypeError
        raise MicrosoftApi::Error.new(502), cause: nil
      end

      def validate_tokens!(data)
        valid = data.is_a?(Hash) && data['token_type'].to_s.casecmp?('bearer') &&
                !data['access_token'].to_s.empty? && data['expires_in'].to_i.positive?
        raise MicrosoftApi::Error, 502 unless valid

        scopes = data['scope'].to_s.split.map { |scope| scope.delete_prefix('https://graph.microsoft.com/') }
        raise MicrosoftApi::Error.new(403, nil, 'insufficient_scope') unless (GRAPH_SCOPES - scopes).empty?
      end

      def safe_reason(data)
        code = data['error'] if data.is_a?(Hash)
        code if %w[invalid_grant invalid_client invalid_scope interaction_required consent_required].include?(code)
      end
    end
  end
end
