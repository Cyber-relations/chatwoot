# frozen_string_literal: true

require 'json'
require 'uri'
require 'time'
require_relative 'microsoft_authorization_api'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    class MicrosoftApi
      REVISION = 'microsoft-graph-v1'
      SCOPES = MicrosoftAuthorizationApi::SCOPES
      API_URL = 'https://graph.microsoft.com/v1.0/me'
      MAX_ATTACHMENT_BYTES = 25_000_000

      class Error < StandardError
        attr_reader :status, :retry_after, :reason

        def initialize(status, retry_after = nil, reason = nil)
          @status = status.to_i
          @retry_after = retry_after
          @reason = reason
          super("Microsoft request failed (#{@status})")
        end

        def authorization_failure?
          status == 401 || %w[invalid_grant invalid_client interaction_required consent_required insufficient_scope
                              InvalidAuthenticationToken].include?(reason)
        end

        def possibly_accepted?
          status >= 500 || status == 408
        end
      end

      def initialize(transport: MicrosoftTransport.new)
        @transport = transport
      end

      def profile(access_token:)
        get('', access_token, '$select' => 'id,mail,userPrincipalName')
      end

      def inbox(access_token:)
        get('/mailFolders/inbox', access_token, '$select' => 'id')
      end

      def validate_delta_cursor!(cursor, folder_id:)
        validate_cursor!(cursor, "/mailFolders/#{segment(folder_id)}/messages/delta")
      end

      def delta(access_token:, folder_id:, since:, cursor: nil)
        path = "/mailFolders/#{segment(folder_id)}/messages/delta"
        if cursor
          validate_cursor!(cursor, path)
          return request(:get, cursor, access_token)
        end
        boundary = Time.iso8601(since).utc.iso8601
        get(path, access_token, '$select' => 'id,isDraft,receivedDateTime,internetMessageId', '$filter' => "receivedDateTime ge #{boundary}",
                                '$top' => '50')
      end

      def message(access_token:, id:)
        fields = %w[id conversationId internetMessageId internetMessageHeaders subject from toRecipients ccRecipients replyTo
                    body hasAttachments receivedDateTime sentDateTime parentFolderId isDraft].join(',')
        get("/messages/#{segment(id)}", access_token, '$select' => fields)
      end

      def attachments(access_token:, id:, cursor: nil)
        path = "/messages/#{segment(id)}/attachments"
        if cursor
          validate_cursor!(cursor, path)
          return request(:get, cursor, access_token)
        end
        get(path, access_token, '$select' => 'id,name,size,contentType,isInline', '$top' => '20')
      end

      def attachment(access_token:, message_id:, id:)
        path = "/messages/#{segment(message_id)}/attachments/#{segment(id)}/$value"
        raw_request(:get, API_URL + path, access_token, maximum: MAX_ATTACHMENT_BYTES)
      end

      def attachment_details(access_token:, message_id:, id:)
        # Inline Content-ID belongs to the derived fileAttachment type. Fetch
        # its documented representation only after checking size/count metadata.
        path = "/messages/#{segment(message_id)}/attachments/#{segment(id)}"
        parse_response(raw_request(:get, API_URL + path, access_token, maximum: 36_000_000))
      end

      def request(method, url, token, data = nil)
        body = data && JSON.generate(data)
        response = raw_request(method, url, token, body: body)
        parse_response(response)
      end

      def raw_request(method, url, token, body: nil, maximum: 4_000_000)
        raise ArgumentError, 'missing Microsoft authorization' if token.to_s.empty? || token.to_s.match?(/[\r\n]/)

        headers = { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json',
                    'Prefer' => 'IdType="ImmutableId", odata.maxpagesize=50' }
        response = @transport.call(method: method, url: url, headers: headers, body: body, max_bytes: maximum)
        raise Error.new(response[:status], response[:retry_after], error_reason(response[:body])) unless (200..299).cover?(response[:status])

        response
      end

      private

      def parse_response(response)
        result = response[:body].empty? ? {} : JSON.parse(response[:body], allow_duplicate_key: false)
        raise Error, 502 unless result.is_a?(Hash)

        result
      rescue JSON::ParserError
        raise Error.new(502), cause: nil
      end

      def get(path, token, params = {})
        query = params.empty? ? '' : "?#{URI.encode_www_form(params)}"
        request(:get, API_URL + path + query, token)
      end

      def segment(id)
        raise ArgumentError, 'invalid Microsoft resource ID' unless id.is_a?(String) && id.match?(%r{\A[A-Za-z0-9_=+/-]{1,2048}\z})

        URI.encode_www_form_component(id)
      end

      def validate_cursor!(cursor, path)
        uri = URI(cursor)
        expected = URI(API_URL + path)
        valid = cursor_origin?(uri, expected) && cursor.bytesize <= 16_384 &&
                URI.decode_www_form_component(uri.path) == URI.decode_www_form_component(expected.path)
        raise ArgumentError, 'invalid Microsoft continuation' unless valid
      rescue URI::InvalidURIError
        raise ArgumentError, 'invalid Microsoft continuation'
      end

      def cursor_origin?(uri, expected)
        uri.scheme == 'https' && uri.host == expected.host && uri.port == 443 && !uri.userinfo && !uri.fragment
      end

      def error_reason(body)
        data = JSON.parse(body.to_s)
        code = data.dig('error', 'code') if data.is_a?(Hash) && data['error'].is_a?(Hash)
        code if %w[InvalidAuthenticationToken ErrorAccessDenied ErrorInvalidSyncStateData SyncStateNotFound].include?(code)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
