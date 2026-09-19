# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require_relative '../overlay/app/lib/toybaco/connections/handoff/mail_oauth_state'

class ToybacoHandoffMailStateTest < Minitest::Test
  Handoff = Toybaco::Connections::Handoff
  NOW = Time.utc(2026, 9, 19, 8)
  ID = '12121212-3434-4567-89ab-121212121212'
  BINDING = { public_id: ID, provider: 'gmail', browser_nonce: 'a' * 64, application: 'b' * 64 }.freeze

  class Store
    attr_reader :values, :writes
    attr_accessor :now, :cas

    def initialize
      @now = NOW.to_i
      @values = {}
      @expires = {}
      @writes = []
      @cas = 1
    end

    def get(key)
      @values.delete(key) if @expires[key] && @expires[key] <= now
      @values[key]
    end

    def set(key, value, nx: false, ex:)
      return false if nx && get(key)

      @writes << [key, ex]
      @values[key] = value
      @expires[key] = now + ex
      'OK'
    end

    def delete_if_equals(key, value)
      return 0 unless @cas == 1 && get(key) == value

      @values.delete(key)
      [1]
    end
  end

  def setup
    @store = Store.new
  end

  def state
    Handoff::MailOauthState.new(store: @store, now: Time.at(@store.now).utc)
  end

  def issue(**changes)
    state.issue(**BINDING.merge(expires_at: NOW + 86_400).merge(changes))
  end

  def consume(saved, **changes)
    state.consume(saved.fetch('state'), **BINDING.merge(changes))
  end

  def test_pkce_round_trip_is_one_use_and_does_not_store_raw_state_or_nonce
    saved = issue
    raw = @store.values.fetch(Handoff::MailOauthState::PREFIX + ID)
    refute_includes raw, saved.fetch('state')
    refute_includes raw, BINDING.fetch(:browser_nonce)
    payload = consume(saved)
    assert_equal ID, payload.fetch('public_id')
    assert_equal 'gmail', payload.fetch('provider')
    assert_equal saved.fetch('challenge'), Base64.urlsafe_encode64(Digest::SHA256.digest(payload.fetch('verifier')), padding: false)
    assert_nil consume(saved)
    assert_equal [10, 900], @store.writes.map(&:last)
  end

  def test_wrong_browser_provider_application_or_record_does_not_consume_valid_state
    saved = issue
    [{ browser_nonce: 'c' * 64 }, { provider: 'microsoft' }, { application: 'd' * 64 },
     { public_id: '34343434-3434-4567-89ab-121212121212' }].each do |changes|
      assert_nil consume(saved, **changes)
    end
    assert consume(saved)
  end

  def test_cas_failure_cannot_return_a_valid_authorization
    saved = issue
    @store.cas = 'OK'
    assert_nil consume(saved)
    @store.cas = 1
    assert consume(saved)
  end

  def test_superseded_authorization_is_rejected_and_memory_is_bounded_per_request
    first = issue
    assert_raises(Handoff::Limited) { issue }
    @store.now += 10
    second = issue
    assert_equal 2, @store.values.size
    assert_nil consume(first)
    assert consume(second)
  end

  def test_link_expiry_caps_state_ttl_and_expired_links_cannot_issue
    saved = issue(expires_at: NOW + 12)
    assert_equal 12, @store.writes.last.last
    @store.now += 12
    assert_nil consume(saved)
    assert_raises(Handoff::Forbidden) { issue(expires_at: NOW + 12) }
  end

  def test_mutated_payload_types_extra_fields_and_duplicate_keys_fail_closed
    saved = issue
    key = Handoff::MailOauthState::PREFIX + ID
    original = @store.values.fetch(key)
    malformed = [[], { 'expires_at' => '99999999999' }]
    %w[expires_at verifier application public_id provider].each do |name|
      malformed << JSON.parse(original).merge(name => nil)
    end
    malformed << JSON.parse(original).merge('account_id' => 999)
    malformed.each do |payload|
      @store.values[key] = JSON.generate(payload)
      assert_nil consume(saved)
    end
    @store.values[key] = original.sub('{', '{"provider":"microsoft",')
    assert_nil consume(saved)
    @store.values[key] = original
    assert consume(saved)
  end

  def test_oversized_value_invalid_token_and_expiry_extension_are_rejected
    saved = issue
    key = Handoff::MailOauthState::PREFIX + ID
    original = @store.values.fetch(key)
    @store.values[key] = 'x' * 8193
    assert_nil consume(saved)
    @store.values[key] = JSON.generate(JSON.parse(original).merge('expires_at' => NOW.to_i + 901))
    assert_nil consume(saved)
    @store.values[key] = original
    assert_nil state.consume('invalid', **BINDING)
    assert consume(saved)
  end

  def test_invalid_binding_does_not_write_redis
    [{ provider: 'line' }, { browser_nonce: '' }, { public_id: 1 }, { application: 'callback' }].each do |change|
      assert_raises(Handoff::Forbidden) { issue(**change) }
    end
    assert_empty @store.writes
  end

  def test_unavailable_store_does_not_return_an_authorization_url
    @store.stub(:set, false) { assert_raises(Handoff::Limited) { issue } }
    count = 0
    operation = lambda do |*_args, **_options|
      count += 1
      count == 1 ? 'OK' : nil
    end
    @store.stub(:set, operation) { assert_raises(Handoff::Unavailable) { issue } }
  end
end
