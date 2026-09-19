# frozen_string_literal: true

require 'json'
require 'net/http'
require 'aws-sdk-core'
require 'aws-sigv4'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class DraftModel
      MODEL = 'jp.anthropic.claude-haiku-4-5-20251001-v1:0'
      REGION = 'ap-northeast-1'
      MAX_BYTES = 65_536
      class Unavailable < StandardError; end

      def initialize(credentials: nil)
        @credentials = credentials
      end

      def generate(body)
        uri = URI("https://bedrock-runtime.#{REGION}.amazonaws.com/model/#{URI.encode_www_form_component(MODEL)}/invoke")
        payload = JSON.generate(body)
        headers = { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }
        headers = headers.merge(signer.sign_request(http_method: 'POST', url: uri.to_s, headers: headers, body: payload).headers)
        request = Net::HTTP::Post.new(uri.request_uri, headers)
        request.body = payload
        parse(perform(uri, request))
      end

      def parse(raw)
        raise Unavailable, 'invalid generation response' if raw.bytesize > MAX_BYTES

        data = JSON.parse(raw, max_nesting: 32, allow_nan: false, allow_duplicate_key: false)
        blocks = data['content'] if valid_envelope?(data)
        raise Unavailable, 'invalid generation response' unless blocks.is_a?(Array) && blocks.one?

        result(blocks.first)
      rescue JSON::ParserError
        raise Unavailable, 'invalid generation response'
      end

      private

      def valid_envelope?(data)
        data.is_a?(Hash) && data['type'] == 'message' && data['role'] == 'assistant' && data['stop_reason'] == 'tool_use'
      end

      def signer
        @credentials ||= Aws::ECSCredentials.new
        Aws::Sigv4::Signer.new(service: 'bedrock', region: REGION, credentials_provider: @credentials)
      end

      def perform(uri, request)
        raw = +''
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 40, write_timeout: 10) do |http|
          http.max_retries = 0
          http.request(request) do |response|
            raise Unavailable, 'generation unavailable' unless response.code == '200'

            response.read_body do |chunk|
              raw << chunk
              raise Unavailable, 'invalid generation response' if raw.bytesize > MAX_BYTES
            end
          end
        end
        raw
      end

      def result(block)
        input = block['input'] if valid_block?(block)
        raise Unavailable, 'invalid generation response' unless input.is_a?(Hash) && input.keys.sort == %w[content needs_review]
        raise Unavailable, 'invalid generation response' unless [true, false].include?(input['needs_review']) && valid_text?(input['content'])

        input.to_h
      end

      def valid_block?(block)
        block.is_a?(Hash) && block.keys.sort == %w[id input name type] && block['type'] == 'tool_use' && block['name'] == tool_name
      end

      def tool_name
        'reply_draft'
      end

      def valid_text?(text)
        text.is_a?(String) && !text.strip.empty? && text.length <= 1600 && !text.match?(/\x00|\[\[(?:HANDOFF|NOTIFY)\]\]/)
      end
    end
  end
end
