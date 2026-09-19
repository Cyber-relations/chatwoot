# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require_relative '../overlay/app/lib/toybaco/connections/line_setup_api'

class ToybacoLineSetupApiTest < Minitest::Test
  Api = Toybaco::Connections::LineSetupApi
  Response = Struct.new(:code, :type, :chunks) do
    def [](name)
      type if name == 'content-type'
    end

    def read_body(&block)
      chunks.each(&block)
    end
  end
  class Http
    attr_accessor :use_ssl, :verify_mode, :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :requests

    def initialize(response)
      @response = response
      @requests = []
    end

    def start
      yield self
    end

    def request(request)
      @requests << request
      raise @response if @response.is_a?(Exception)

      yield @response
    end
  end

  def call(body: '{"client_id":"1234567890","expires_in":2147483647}', status: '200', type: 'application/json', chunks: nil)
    @http = Http.new(Response.new(status, type, chunks || [body]))
    Net::HTTP.stub(:new, lambda { |host, port|
      assert_equal ['api.line.me', 443], [host, port]
      @http
    }) { Api.new.verify!(channel_id: '1234567890', access_token: 'fixture+/=' * 5) }
  end

  def test_verification_uses_fixed_https_form_and_no_secret_in_url
    assert call
    request = @http.requests.fetch(0)
    assert_equal 'POST', request.method
    assert_equal '/v2/oauth/verify', request.path
    assert_equal({ 'access_token' => 'fixture+/=' * 5 }, URI.decode_www_form(request.body).to_h)
    assert_nil request['authorization']
    assert_equal true, @http.use_ssl
    assert_equal OpenSSL::SSL::VERIFY_PEER, @http.verify_mode
    assert_equal [5, 10, 10, 0], [@http.open_timeout, @http.read_timeout, @http.write_timeout, @http.max_retries]
    assert_equal 1, @http.requests.length
  end

  def test_wrong_channel_and_non_string_client_identifier_are_rejected
    ['{"client_id":"99999"}', '{"client_id":1234567890}', '[]', '{}'].each do |body|
      assert_raises(Api::Error) { call(body: body) }
    end
  end

  def test_redirect_and_provider_error_are_not_followed_or_exposed
    %w[301 302 400 401 429 500].each do |status|
      failure = assert_raises(Api::Error) { call(status: status, body: '{"error":"private-provider-detail"}') }
      refute_includes failure.message, 'private-provider-detail'
      assert_equal 1, @http.requests.length
    end
  end

  def test_malformed_duplicate_or_deep_json_and_non_json_responses_are_rejected
    ['invalid', '{"client_id":"1234567890","client_id":"1234567890"}', ('[' * 9) + (']' * 9)].each do |body|
      assert_raises(Api::Error) { call(body: body) }
    end
    assert_raises(Api::Error) { call(type: 'text/html') }
  end

  def test_streamed_response_is_bounded_in_bytes_and_time
    assert_raises(Api::Error) { call(chunks: [' ' * 32768, ' ' * 32769]) }
    ticks = [0, 16]
    Process.stub(:clock_gettime, ->(*) { ticks.shift || 16 }) { assert_raises(Api::Error) { call } }
  end

  def test_io_and_total_timeout_are_not_retried
    http = Http.new(IOError.new('fixture'))
    Net::HTTP.stub(:new, http) do
      assert_raises(Api::Error) { Api.new.verify!(channel_id: '1234567890', access_token: 'private-fixture') }
    end
    assert_equal 1, http.requests.length
    Timeout.stub(:timeout, ->(seconds, klass) { assert_equal 15, seconds; raise klass }) do
      assert_raises(Api::Error) { call }
    end
  end
end
