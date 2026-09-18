# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'base64'
require_relative 'gmail_transport'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    # The REST adapter uses read + send. It never asks for permanent deletion,
    # changes mailbox settings, or falls back to an IMAP/SMTP password.
    class GmailApi
      SCOPES = %w[https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.send].freeze
      REVISION = 'gmail-rest-v1'
      AUTHORIZE_URL = 'https://accounts.google.com/o/oauth2/v2/auth'
      TOKEN_URL = 'https://oauth2.googleapis.com/token'
      API_URL = 'https://gmail.googleapis.com/gmail/v1/users/me'
      MAX_RESPONSE_BYTES = 36 * 1024 * 1024
      MAX_MESSAGE_BYTES = 25 * 1024 * 1024

      class Error < StandardError
        attr_reader :status, :retry_after, :reason

        def initialize(status, retry_after = nil, reason = nil)
          @status = status.to_i
          @retry_after = retry_after
          @reason = reason
          # Do not put provider error bodies, addresses or credentials in logs.
          super("Gmail request failed (#{@status})")
        end

        def authorization_failure?
          status == 401 || %w[invalid_grant invalid_token insufficientPermissions insufficient_scope].include?(reason)
        end

        def possibly_accepted?
          status >= 500 || status == 408
        end
      end

      def initialize(client_id:, client_secret:, redirect_uri:, transport: GmailTransport.new)
        @client_id = client_id
        @client_secret = client_secret
        @redirect_uri = redirect_uri
        @transport = transport
      end

      def authorization_url(state:, challenge:)
        raise ArgumentError, 'Gmail is not configured' if @client_id.to_s.empty? || @client_secret.to_s.empty?
        raise ArgumentError, 'invalid OAuth state' unless state.to_s.match?(/\A[0-9a-f]{64}\z/) && challenge.to_s.match?(/\A[A-Za-z0-9_-]{43}\z/)

        query = { client_id: @client_id, redirect_uri: @redirect_uri, response_type: 'code', scope: SCOPES.join(' '),
                  access_type: 'offline', prompt: 'consent', state: state, code_challenge: challenge, code_challenge_method: 'S256' }
        "#{AUTHORIZE_URL}?#{URI.encode_www_form(query)}"
      end

      def exchange(code:, verifier:)
        token(require_scopes: true, grant_type: 'authorization_code', code: code, code_verifier: verifier, redirect_uri: @redirect_uri)
      end

      def refresh(refresh_token:)
        token(grant_type: 'refresh_token', refresh_token: refresh_token)
      end

      def profile(access_token:)
        get('/profile', access_token)
      end

      def history(access_token:, history_id:, page_token: nil)
        get('/history', access_token,
            { startHistoryId: history_id, historyTypes: %w[messageAdded labelAdded], maxResults: 100, pageToken: page_token }.compact)
      end

      def messages(access_token:, since:, page_token: nil)
        raise ArgumentError, 'invalid sync boundary' unless since.is_a?(Integer) && since.positive?

        get('/messages', access_token, { q: "after:#{since} -in:spam -in:trash -in:sent -in:drafts", maxResults: 100, pageToken: page_token }.compact)
      end

      def message(access_token:, id:)
        raise ArgumentError, 'invalid Gmail message ID' unless id.to_s.match?(/\A[a-zA-Z0-9_-]+\z/)

        get("/messages/#{id}", access_token, format: 'full')
      end

      def attachment(access_token:, message_id:, id:)
        valid = [message_id, id].all? { |value| value.is_a?(String) && value.match?(/\A[a-zA-Z0-9_-]+\z/) }
        raise ArgumentError, 'invalid Gmail attachment ID' unless valid

        get("/messages/#{message_id}/attachments/#{id}", access_token)
      end

      def sent_message(access_token:, message_id:)
        raise ArgumentError, 'invalid RFC message ID' unless message_id.to_s.match?(/\A[a-zA-Z0-9_.+\-]+@[a-zA-Z0-9.\-]+\z/)

        get('/messages', access_token, q: "in:sent rfc822msgid:#{message_id}", maxResults: 2)
      end

      def send_message(access_token:, raw:, thread_id: nil)
        raise ArgumentError, 'message too large' if raw.bytesize > MAX_MESSAGE_BYTES

        data = { raw: Base64.urlsafe_encode64(raw, padding: false) }
        data[:threadId] = thread_id if thread_id
        request(:post, "#{API_URL}/messages/send", auth(access_token), JSON.generate(data))
      end

      def revoke(refresh_token:)
        request(:post, 'https://oauth2.googleapis.com/revoke', { 'Content-Type' => 'application/x-www-form-urlencoded' },
                URI.encode_www_form(token: refresh_token))
      end

      private

      def token(require_scopes: false, **params)
        params = params.merge(client_id: @client_id, client_secret: @client_secret)
        result = request(:post, TOKEN_URL, { 'Content-Type' => 'application/x-www-form-urlencoded' }, URI.encode_www_form(params))
        raise Error, 502 if result['access_token'].to_s.empty? || result['expires_in'].to_i <= 0
        # Scope can be absent on refresh; keep the previously verified scope set.
        raise Error.new(403, nil, 'insufficient_scope') if (require_scopes || result.key?('scope')) && (SCOPES - result['scope'].to_s.split).any?

        result
      end

      def auth(access_token)
        raise ArgumentError, 'missing Gmail authorization' if access_token.to_s.empty? || access_token.to_s.match?(/[\r\n]/)

        { 'Authorization' => "Bearer #{access_token}", 'Content-Type' => 'application/json' }
      end

      def get(path, access_token, params = {})
        query = params.empty? ? '' : "?#{URI.encode_www_form(params)}"
        request(:get, API_URL + path + query, auth(access_token))
      end

      def error_reason(body)
        error = JSON.parse(body.to_s)['error']
        reason = error.is_a?(Hash) ? error.fetch('errors', []).first&.fetch('reason', nil) : error
        # Retain only known codes, never arbitrary upstream descriptions.
        allowed = %w[invalid_grant invalid_token insufficientPermissions insufficient_scope rateLimitExceeded userRateLimitExceeded]
        allowed.include?(reason) ? reason : nil
      rescue JSON::ParserError, TypeError, NoMethodError
        nil
      end

      def request(method, url, headers, body = nil)
        response = @transport.call(method: method, url: url, headers: headers, body: body)
        raise Error.new(response[:status], response[:retry_after], error_reason(response[:body])) unless (200..299).cover?(response[:status])

        result = response[:body].to_s.empty? ? {} : JSON.parse(response[:body])
        raise Error, 502 unless result.is_a?(Hash)

        result
      rescue JSON::ParserError
        raise Error.new(502), cause: nil
      end
    end
  end
end
