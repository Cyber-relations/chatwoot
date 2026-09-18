# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../overlay/app/lib/toybaco/connections/oauth_state'
require_relative '../overlay/app/lib/toybaco/connections/gmail_api'

class ToybacoConnectionOauthTest < Minitest::Test
  State = Toybaco::Connections::OauthState
  Gmail = Toybaco::Connections::GmailApi
  NOW = Time.utc(2026, 9, 18)
  NONCE = 'b' * 64

  class Store
    attr_reader :values, :expiry
    attr_accessor :lose_race

    def initialize
      @values = {}
    end

    def set(key, value, nx:, ex:)
      return false if nx && @values.key?(key)

      @expiry = ex
      @values[key] = value
      true
    end

    def get(key)
      @values[key]
    end

    def delete_if_equals(key, value)
      return 'OK' if lose_race
      return [0] unless @values[key] == value

      @values.delete(key)
      [1]
    end
  end

  def setup
    @store = Store.new
    @state = State.new(store: @store, now: NOW)
    @issued = @state.issue(account_id: 4, user_id: 6, browser_nonce: NONCE, provider: 'gmail', return_to: 'onboarding')
    @calls = []
    @response = { status: 200, body: '{}' }
    transport = lambda { |**args| @calls << args; @response }
    @gmail = Gmail.new(client_id: 'fixture-client', client_secret: 'fixture-secret',
      redirect_uri: 'https://app.example.test/toybaco/connections/gmail/callback', transport: transport)
  end

  def consume(**binding)
    @state.consume(@issued['state'], **{ user_id: 6, browser_nonce: NONCE, provider: 'gmail' }.merge(binding))
  end

  def test_state_is_one_use_and_retains_only_server_selected_account_and_return
    result = consume
    assert_equal 4, result['account_id']
    assert_equal 'onboarding', result['return_to']
    assert_equal State::TTL, @store.expiry
    assert_nil consume
    refute result.key?('return_url')
    refute result.values.include?(NONCE)
  end

  def test_wrong_user_browser_or_provider_cannot_take_connection
    assert_nil consume(user_id: 7)
    assert_nil consume(browser_nonce: 'c' * 64)
    assert_nil consume(provider: 'microsoft')
    assert_equal 4, consume['account_id']
  end

  def test_concurrent_callback_loser_is_not_accepted
    @store.lose_race = true
    assert_nil consume
  end

  def test_expired_state_and_untrusted_return_url_are_rejected
    later = State.new(store: @store, now: NOW + State::TTL)
    assert_nil later.consume(@issued['state'], user_id: 6, browser_nonce: NONCE, provider: 'gmail')
    assert_raises(ArgumentError) do
      @state.issue(account_id: 4, user_id: 6, browser_nonce: NONCE, provider: 'gmail', return_to: 'https://evil.example/')
    end
  end

  def test_oauth_uses_only_read_send_and_pkce_with_no_deletion_or_imap_scope
    url = URI(@gmail.authorization_url(state: @issued['state'], challenge: @issued['challenge']))
    params = URI.decode_www_form(url.query).to_h
    assert_equal 'accounts.google.com', url.host
    assert_equal Gmail::SCOPES, params['scope'].split
    assert_equal 'S256', params['code_challenge_method']
    payload = consume
    assert_equal Base64.urlsafe_encode64(Digest::SHA256.digest(payload['verifier']), padding: false), params['code_challenge']
    refute params.values.include?('fixture-secret')
  end

  def test_missing_granted_permission_is_not_a_successful_connection
    @response = { status: 200, body: JSON.generate(access_token: 'fixture', expires_in: 3600, scope: Gmail::SCOPES.first) }
    error = assert_raises(Gmail::Error) { @gmail.exchange(code: 'test-code', verifier: 'test-verifier') }
    assert_equal 403, error.status
  end

  def test_send_is_once_and_non_2xx_does_not_expose_the_provider_body
    @response = { status: 503, body: 'private-provider-data' }
    error = assert_raises(Gmail::Error) { @gmail.send_message(access_token: 'fixture-token', raw: 'test-message') }
    assert_equal 1, @calls.size
    refute_includes error.message, 'private-provider-data'
    payload = JSON.parse(@calls.first[:body])
    assert_equal 'test-message', Base64.urlsafe_decode64(payload['raw'])
  end

  def test_raw_message_too_large_and_unsafe_message_id_never_reach_transport
    assert_raises(ArgumentError) { @gmail.send_message(access_token: 'fixture-token', raw: 'x' * (Gmail::MAX_MESSAGE_BYTES + 1)) }
    assert_raises(ArgumentError) { @gmail.message(access_token: 'fixture-token', id: '../profile') }
    assert_empty @calls
  end

  def test_pagination_cursor_and_history_are_encoded_not_interpreted_as_url
    @gmail.history(access_token: 'fixture-token', history_id: '100', page_token: 'foo&startHistoryId=0')
    query = URI.decode_www_form(URI(@calls.first[:url]).query).to_h
    assert_equal '100', query['startHistoryId']
    assert_equal 'foo&startHistoryId=0', query['pageToken']
    assert_equal %w[messageAdded labelAdded], URI.decode_www_form(URI(@calls.first[:url]).query).select { |key, _| key == 'historyTypes' }.map(&:last)
  end

  def test_malformed_success_is_not_an_empty_mailbox
    @response = { status: 200, body: '<html>not JSON</html>' }
    assert_raises(Gmail::Error) { @gmail.profile(access_token: 'fixture-token') }
    @response = { status: 200, body: '[]' }
    assert_raises(Gmail::Error) { @gmail.profile(access_token: 'fixture-token') }
  end

  def test_rate_limit_is_returned_without_an_internal_retry_loop
    @response = { status: 429, body: '{}', retry_after: '60' }
    error = assert_raises(Gmail::Error) { @gmail.profile(access_token: 'fixture-token') }
    assert_equal '60', error.retry_after
    assert_equal 1, @calls.length
  end
  def test_quota_errors_do_not_prompt_reauthorization_but_invalid_grants_do
    @response = { status: 403, body: JSON.generate(error: { errors: [{ reason: 'userRateLimitExceeded' }] }) }
    error = assert_raises(Gmail::Error) { @gmail.profile(access_token: 'fixture-token') }
    refute error.authorization_failure?
    refute error.possibly_accepted?
    @response = { status: 400, body: JSON.generate(error: 'invalid_grant') }
    error = assert_raises(Gmail::Error) { @gmail.refresh(refresh_token: 'fixture-token') }
    assert error.authorization_failure?
  end

  def test_timeout_status_is_ambiguous_and_unknown_error_text_is_discarded
    @response = { status: 408, body: JSON.generate(error: 'private-provider-data') }
    error = assert_raises(Gmail::Error) { @gmail.send_message(access_token: 'fixture-token', raw: 'test-message') }
    assert error.possibly_accepted?
    assert_nil error.reason
    refute_includes error.message, 'private-provider-data'
  end

end
