# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'timeout'

puts 'TOYBACO_WIDGET_HTTP_SUITE_BEGIN'
Minitest.after_run { puts 'TOYBACO_WIDGET_HTTP_SUITE_END' }

# Test-only injection at the actual callback boundary, after header resolution
# and before the business action. It is never included in the product image.
module ToybacoWidgetHttpRaceFixture
  private

  def with_toybaco_http_session_fence(&block)
    if request.headers['X-Synthetic-Race'] == 'revoke'
      @toybaco_http_session.record.update!(revoked_at: Time.current)
    elsif request.headers['X-Synthetic-Race'] == 'rebind'
      link = ContactInbox.find(request.headers['X-Synthetic-Link'])
      @toybaco_http_session.rebind!(link)
    end
    super(&block)
  end
end

Api::V1::Widget::ContactsController.prepend(ToybacoWidgetHttpRaceFixture)

module ToybacoWidgetHttpLinkLockFixture
  def with_lock(*args, &block)
    gate = Thread.current[:toybaco_widget_link_lock_fixture]
    if gate
      Thread.current[:toybaco_widget_link_lock_fixture] = nil
      gate[:ready] << true
      gate[:continue].pop
    end
    super
  end
end
ContactInbox.prepend(ToybacoWidgetHttpLinkLockFixture)

module ToybacoWidgetHttpMergePauseFixture
  private

  def merge_conversations
    super
    gate = Thread.current[:toybaco_widget_merge_pause_fixture]
    if gate
      gate[:ready] << true
      gate[:continue].pop
    end
  end
end
ContactMergeAction.prepend(ToybacoWidgetHttpMergePauseFixture)

class ToybacoWidgetHttpFenceHarness
  include Toybaco::Security::WidgetHttpRequestFence
  attr_reader :request

  def initialize(session, widget, request)
    @toybaco_http_session = session
    @contact_inbox = session.record.contact_inbox
    @auth_token_params = session.claims
    @web_widget = widget
    @request = request
  end

  def call(&block)
    with_toybaco_http_session_fence { block ? block.call : :api_completed }
  end

  def action_name
    'show'
  end
end

class ToybacoWidgetHttpSessionRuntimeTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = true

  def setup
    host! 'www.example.com'
    https!
    @previous_show_exceptions = Rails.application.env_config['action_dispatch.show_exceptions']
    Rails.application.env_config['action_dispatch.show_exceptions'] = :none
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @widgets = 2.times.map do
      account = Account.create!(name: 'Synthetic HTTP Widget')
      widget = Channel::WebWidget.create!(account: account, website_url: 'https://customer.example.test')
      Inbox.create!(account: account, channel: widget, name: 'Synthetic HTTP Widget')
      widget
    end
    @links = @widgets.map do |widget|
      contact = Contact.create!(account: widget.account, name: 'Synthetic returning visitor')
      ContactInbox.create!(contact: contact, inbox: widget.inbox, source_id: SecureRandom.uuid)
    end
    @legacy = @links.map { |link| token_for(link) }
    @intent = SecureRandom.hex(32)
  end

  def teardown
    ActiveJob::Base.queue_adapter = @previous_adapter
    Rails.application.env_config['action_dispatch.show_exceptions'] = @previous_show_exceptions
  end

  def token_for(link)
    Widget::TokenService.new(payload: { inbox_id: link.inbox_id, source_id: link.source_id }).generate_token
  end

  def headers_for(proof = nil)
    { 'X-Toybaco-Widget' => '1', 'Origin' => 'https://www.example.com', 'Sec-Fetch-Site' => 'same-origin' }
      .merge(proof ? { 'X-Auth-Token' => proof } : {})
  end

  def issue(legacy: @legacy[0], intent: @intent)
    post '/api/v1/widget/http_session', params: { website_token: @widgets[0].website_token,
      legacy_token: legacy, consume_intent: intent }, headers: headers_for, as: :json
    assert_response :success
    @issued = response.parsed_body
    @proof = @issued.fetch('proof')
  end

  def clear_browser_cookies
    # Rack::Test::CookieJar has no clear method in the locked dependency.
    # Start a fresh real integration session while keeping its exact origin.
    previous_host = integration_session.host
    previous_https = integration_session.https?
    reset!
    host! previous_host
    https! previous_https
  end

  def with_framework_error_rendering
    config = Rails.application.env_config
    previous = config['action_dispatch.show_exceptions']
    config['action_dispatch.show_exceptions'] = :rescuable
    yield
  ensure
    config['action_dispatch.show_exceptions'] = previous
  end

  def readback
    get '/api/v1/widget/http_session', params: { website_token: @widgets[0].website_token }, headers: headers_for(@proof)
  end

  def contact(proof = @proof, widget: @widgets[0], headers: nil)
    get '/api/v1/widget/contact', params: { website_token: widget.website_token }, headers: headers || headers_for(proof)
  end

  def test_cookie_is_httponly_secure_partitioned_and_no_domain
    issue
    line = Array(response.headers['Set-Cookie']).join('\n')
    assert_includes line.downcase, 'httponly'
    assert_includes line.downcase, 'secure'
    assert_includes line.downcase, 'samesite=none'
    assert_includes line.downcase, 'partitioned'
    assert_includes line.downcase, 'path=/'
    refute_match(/domain=/i, line)
    assert_match(/__Host-tbw_/, line)
    refute_includes response.body, @legacy[0]
    refute_includes response.body, @links[0].pubsub_token
  end

  def test_direct_bootstrap_selects_the_same_legacy_contact_before_http_serialization
    env = Rack::MockRequest.env_for('https://www.example.com/api/v1/widget/http_session',
      'HTTP_ORIGIN' => 'https://www.example.com', 'HTTP_SEC_FETCH_SITE' => 'same-origin', 'HTTP_X_TOYBACO_WIDGET' => '1')
    session, secret = Toybaco::Security::WidgetHttpSession.bootstrap(
      ActionDispatch::Request.new(env), @widgets[0], legacy_token: @legacy[0], intent: @intent
    )
    assert_equal @links[0].id, session.record.contact_inbox_id
    assert_match(/\A[a-f0-9]{64}\z/, secret)
    assert session.valid_proof?(session.proof)
  end

  def test_cookie_and_proof_readback_select_original_contact_and_history
    conversation = Conversation.create!(account: @widgets[0].account, inbox: @widgets[0].inbox,
      contact: @links[0].contact, contact_inbox: @links[0])
    assert_no_difference ['Contact.count', 'ContactInbox.count', 'Conversation.count'] do
      issue
      readback
      assert_response :success
      assert_equal true, response.parsed_body['persisted']
      contact
      assert_response :success
      assert_equal @links[0].contact_id, response.parsed_body['id']
    end
    assert_equal @links[0].id, conversation.reload.contact_inbox_id
    assert Toybaco::WidgetSessionRecord.last.persisted_at
  end

  def test_proof_without_cookie_does_not_authenticate
    issue
    clear_browser_cookies
    contact
    assert_response :not_found
  end

  def test_cookie_without_proof_cannot_read_or_mutate
    issue
    contact(nil)
    assert_response :not_found
    assert_no_difference 'Conversation.count' do
      get '/api/v1/widget/conversations/toggle_status', params: { website_token: @widgets[0].website_token }, headers: headers_for
      assert_response :not_found
    end
  end

  def test_foreign_origin_or_missing_custom_header_cannot_use_cookie_proof
    issue
    [headers_for(@proof).merge('Origin' => 'https://foreign.example.test'),
     headers_for(@proof).merge('Sec-Fetch-Site' => 'cross-site'),
     headers_for(@proof).except('X-Toybaco-Widget')].each do |headers|
      contact(headers: headers)
      assert_response :not_found
    end
  end

  def test_proof_is_scoped_to_its_inbox
    issue
    contact(widget: @widgets[1])
    assert_response :not_found
  end

  def test_cookie_and_different_valid_legacy_identity_are_rejected
    issue
    other = ContactInbox.create!(inbox: @widgets[0].inbox,
      contact: Contact.create!(account: @widgets[0].account), source_id: SecureRandom.uuid)
    contact(token_for(other))
    assert_response :not_found
    post '/api/v1/widget/http_session', params: { website_token: @widgets[0].website_token,
      legacy_token: token_for(other), consume_intent: SecureRandom.hex(32) }, headers: headers_for, as: :json
    assert_response :conflict
    assert_equal 'widget_session_conflict', response.parsed_body['error']
  end

  def test_legacy_header_for_same_contact_remains_compatible
    issue
    contact(@legacy[0], headers: { 'X-Auth-Token' => @legacy[0] })
    assert_response :success
    assert_equal @links[0].contact_id, response.parsed_body['id']
  end

  def test_legacy_config_and_set_user_keep_the_legacy_response_contract_with_a_cookie
    issue
    legacy_headers = { 'X-Auth-Token' => @legacy[0] }
    post '/api/v1/widget/config', params: { website_token: @widgets[0].website_token }, headers: legacy_headers, as: :json
    assert_response :success
    body = response.parsed_body
    token = body.fetch('website_channel_config').fetch('auth_token')
    assert_equal @links[0].source_id, Widget::TokenService.new(token: token).decode_token[:source_id]
    assert_equal @links[0].pubsub_token, body.fetch('contact').fetch('pubsub_token')
    @links[0].contact.update!(identifier: 'old-synthetic-identity')
    patch '/api/v1/widget/contact/set_user', params: { website_token: @widgets[0].website_token,
      identifier: 'new-synthetic-identity', name: 'Returning visitor' }, headers: legacy_headers, as: :json
    assert_response :success
    next_token = response.parsed_body.fetch('widget_auth_token')
    refute response.parsed_body.key?('widget_http_identity_changed')
    refute_match(/\Atbw[pr]1\./, next_token)
    claims = Widget::TokenService.new(token: next_token).decode_token
    assert_equal Toybaco::WidgetSessionRecord.last.contact_inbox.source_id, claims[:source_id]
    contact(next_token, headers: { 'X-Auth-Token' => next_token })
    assert_response :success
  end

  def test_modern_identity_change_returns_a_new_bound_proof_and_explicit_bridge_retirement
    issue
    @links[0].contact.update!(identifier: 'old-synthetic-identity')
    patch '/api/v1/widget/contact/set_user', params: { website_token: @widgets[0].website_token,
      identifier: 'next-synthetic-identity', name: 'Next visitor' }, headers: headers_for(@proof), as: :json
    assert_response :success
    assert_equal true, response.parsed_body['widget_http_identity_changed']
    next_proof = response.parsed_body.fetch('widget_auth_token')
    assert_match(/\Atbwp1\./, next_proof)
    contact(@proof)
    assert_response :not_found
    contact(next_proof)
    assert_response :success
    assert_equal 'next-synthetic-identity', response.parsed_body['identifier']
  end

  def test_lost_response_cookie_alias_survives_identification_with_a_new_cookie_and_stream_proof
    issue
    intent = SecureRandom.hex(32)
    issue(intent: intent)
    clear_browser_cookies
    issue(intent: intent)
    name = Toybaco::Security::WidgetHttpSession.cookie_name(@widgets[0])
    alias_cookie = cookies[name]
    @links[0].contact.update!(identifier: 'before-alias-switch')
    patch '/api/v1/widget/contact/set_user', params: { website_token: @widgets[0].website_token,
      identifier: 'after-alias-switch', name: 'New visitor' }, headers: headers_for(@proof), as: :json
    assert_response :success
    fresh_cookie = cookies[name]
    refute_equal alias_cookie, fresh_cookie
    @proof = response.parsed_body.fetch('widget_auth_token')
    contact
    assert_response :success
    assert_equal 'after-alias-switch', response.parsed_body['identifier']
    session = Toybaco::Security::WidgetHttpSession.socket(request, @widgets[0], @proof)
    assert_equal Toybaco::WidgetSessionRecord.last.id, session.record.id
    cookies[name] = alias_cookie
    contact
    assert_response :not_found
    cookies[name] = fresh_cookie
    readback
    assert_response :success
  end

  def test_bootstrap_retry_is_same_record_after_lost_response
    issue
    clear_browser_cookies
    assert_no_difference ['Toybaco::WidgetSessionRecord.count', 'ContactInbox.count'] do
      issue
      readback
      assert_response :success
    end
  end

  def test_existing_cookie_bootstrap_intent_reconciles_without_a_second_session_or_lost_history
    issue
    row_id = Toybaco::WidgetSessionRecord.last.id
    retry_intent = SecureRandom.hex(32)
    assert_no_difference ['Toybaco::WidgetSessionRecord.count', 'ContactInbox.count'] do
      issue(intent: retry_intent)
      clear_browser_cookies
      issue(intent: retry_intent)
      readback
      assert_response :success
      travel 61.seconds do
        readback
        assert_response :success
        contact
        assert_response :success
        assert_equal @links[0].contact_id, response.parsed_body['id']
      end
    end
    assert_equal row_id, Toybaco::WidgetSessionRecord.last.id
  end

  def test_legacy_bootstrap_intent_cannot_be_reconciled_without_its_original_legacy_proof
    issue
    clear_browser_cookies
    assert_no_difference ['Toybaco::WidgetSessionRecord.count', 'ContactInbox.count'] do
      post '/api/v1/widget/http_session', params: { website_token: @widgets[0].website_token,
        consume_intent: @intent }, headers: headers_for, as: :json
      assert_response :not_found
    end
  end

  def test_bootstrap_rejects_non_string_or_oversized_legacy_proofs_before_creating_identity
    assert_no_difference ['Toybaco::WidgetSessionRecord.count', 'ContactInbox.count'] do
      [{}, [], 123, '', ' ', 'x' * 8193].each do |invalid|
        post '/api/v1/widget/http_session', params: { website_token: @widgets[0].website_token,
          legacy_token: invalid, consume_intent: SecureRandom.hex(32) }, headers: headers_for, as: :json
        assert_response :not_found
      end
    end
  end

  def test_bootstrap_intent_replay_cannot_change_to_another_valid_legacy_identity
    issue
    original_row = Toybaco::WidgetSessionRecord.last
    other = ContactInbox.create!(inbox: @widgets[0].inbox,
      contact: Contact.create!(account: @widgets[0].account), source_id: SecureRandom.uuid)
    clear_browser_cookies
    assert_no_difference ['Toybaco::WidgetSessionRecord.count', 'ContactInbox.count'] do
      post '/api/v1/widget/http_session', params: { website_token: @widgets[0].website_token,
        legacy_token: token_for(other), consume_intent: @intent }, headers: headers_for, as: :json
      assert_response :not_found
    end
    assert_equal @links[0].id, original_row.reload.contact_inbox_id
    issue
    readback
    assert_response :success
    contact
    assert_equal @links[0].contact_id, response.parsed_body['id']
  end

  def test_consume_refuses_a_child_from_another_contact_before_committing_the_grant
    issue
    parent = Toybaco::WidgetSessionRecord.last
    code = Toybaco::Security::WidgetHttpSession.new(parent).handoff
    other = ContactInbox.create!(inbox: @widgets[0].inbox,
      contact: Contact.create!(account: @widgets[0].account), source_id: SecureRandom.uuid)
    clear_browser_cookies
    issue(legacy: token_for(other), intent: SecureRandom.hex(32))
    wrong_session = Toybaco::Security::WidgetHttpSession.new(Toybaco::WidgetSessionRecord.last)
    clear_browser_cookies
    # Fault injection at the child-selection boundary must not commit a grant
    # to a different identity, even when that child is independently current.
    Toybaco::Security::WidgetHttpSession.stub(:bootstrap_from_parent, [wrong_session, nil]) do
      post '/api/v1/widget/http_session/consume', params: { website_token: @widgets[0].website_token,
        handoff_code: code, consume_intent: SecureRandom.hex(32) }, headers: headers_for, as: :json
      assert_response :not_found
    end
    grant = Toybaco::WidgetHandoff.find_by!(code_digest: Toybaco::Security::WidgetHttpSession.digest(code))
    assert_nil grant.consumed_at
    assert_nil grant.consumed_session_id
    assert_equal @links[0].id, parent.reload.contact_inbox_id
  end

  def test_expired_bootstrap_intent_does_not_create_another_contact
    issue
    clear_browser_cookies
    travel 61.seconds do
      assert_no_difference 'ContactInbox.count' do
        post '/api/v1/widget/http_session', params: { website_token: @widgets[0].website_token,
          legacy_token: @legacy[0], consume_intent: @intent }, headers: headers_for, as: :json
        assert_response :not_found
      end
    end
  end

  def test_short_proof_expiry_has_explicit_renewal_before_business_action
    issue
    old_proof = @proof
    travel 24.hours + 1.second do
      contact(old_proof)
      assert_response :unauthorized
      assert_equal 'widget_proof_expired', response.parsed_body['error']
      post '/api/v1/widget/http_session/proof', params: { website_token: @widgets[0].website_token },
        headers: headers_for(old_proof), as: :json
      assert_response :success
      contact(response.parsed_body.fetch('proof'))
      assert_response :success
    end
  end

  def test_readback_and_proof_responses_cannot_overwrite_a_newer_identity_cookie
    issue
    readback
    assert_response :success
    readback_cookies = Array(response.headers['Set-Cookie'])
    post '/api/v1/widget/http_session/proof', params: { website_token: @widgets[0].website_token },
      headers: headers_for(@proof), as: :json
    assert_response :success
    proof_cookies = Array(response.headers['Set-Cookie'])
    @links[0].contact.update!(identifier: 'before-cookie-switch')
    patch '/api/v1/widget/contact/set_user', params: { website_token: @widgets[0].website_token,
      identifier: 'after-cookie-switch' }, headers: headers_for(@proof), as: :json
    assert_response :success
    name = Toybaco::Security::WidgetHttpSession.cookie_name(@widgets[0])
    assert Array(response.headers['Set-Cookie']).any? { |line| line.include?(name) }
    assert readback_cookies.none? { |line| line.include?(name) }, 'A delayed readback cannot carry an old session cookie'
    assert proof_cookies.none? { |line| line.include?(name) }, 'A delayed proof renewal cannot carry an old session cookie'
    @proof = response.parsed_body.fetch('widget_auth_token')
    readback
    assert_response :success
  end

  def test_cookie_denial_recovery_is_not_persistence_and_is_two_hours
    issue
    clear_browser_cookies
    post '/api/v1/widget/http_session/recover', params: { website_token: @widgets[0].website_token,
      handoff_code: @issued['recovery_code'], consume_intent: @intent }, headers: headers_for, as: :json
    assert_response :success
    recovery = response.parsed_body.fetch('proof')
    assert_equal false, response.parsed_body['persisted']
    contact(recovery)
    assert_response :success
    travel 2.hours + 1.second do
      contact(recovery)
      assert_response :not_found
    end
  end

  def test_a_malformed_cookie_does_not_override_a_valid_recovery_but_cannot_authenticate_a_cookie_proof
    issue
    cookie_name = Toybaco::Security::WidgetHttpSession.cookie_name(@widgets[0])
    post '/api/v1/widget/http_session/recover', params: { website_token: @widgets[0].website_token,
      handoff_code: @issued['recovery_code'], consume_intent: @intent }, headers: headers_for, as: :json
    assert_response :success
    recovery = response.parsed_body.fetch('proof')
    cookies[cookie_name] = 'invalid-synthetic-cookie'
    contact(recovery)
    assert_response :success
    assert_equal @links[0].contact_id, response.parsed_body['id']
    contact(@proof)
    assert_response :not_found
  end

  def test_recovery_for_another_row_cannot_revoke_the_victim_session
    issue
    victim = Toybaco::Security::WidgetHttpSession.new(Toybaco::WidgetSessionRecord.last)
    other = ContactInbox.create!(inbox: @widgets[0].inbox,
      contact: Contact.create!(account: @widgets[0].account), source_id: SecureRandom.uuid)
    clear_browser_cookies
    issue(legacy: token_for(other), intent: SecureRandom.hex(32))
    attacker = Toybaco::WidgetSessionRecord.last
    token = Toybaco::Security::WidgetHttpSession.recovery_token(attacker, expires_at: 2.hours.from_now)
    assert_raises(ActiveRecord::RecordNotFound) { victim.revoke!(token, @widgets[0]) }
    assert_nil victim.record.reload.revoked_at
    assert attacker.reload.current?
  end

  def test_a_different_valid_cookie_still_conflicts_with_recovery_identity
    issue
    name = Toybaco::Security::WidgetHttpSession.cookie_name(@widgets[0])
    original_cookie = cookies[name]
    other = ContactInbox.create!(inbox: @widgets[0].inbox,
      contact: Contact.create!(account: @widgets[0].account), source_id: SecureRandom.uuid)
    clear_browser_cookies
    issue(legacy: token_for(other), intent: SecureRandom.hex(32))
    token = Toybaco::Security::WidgetHttpSession.recovery_token(Toybaco::WidgetSessionRecord.last, expires_at: 2.hours.from_now)
    cookies[name] = original_cookie
    contact(token)
    assert_response :not_found
  end

  def test_expired_authorization_sweep_keeps_live_cookie_aliases_and_all_contact_history
    issue
    live = Toybaco::WidgetSessionRecord.last
    bridge = Toybaco::WidgetHandoff.find_by!(widget_session_record_id: live.id, kind: 'bootstrap')
    bridge.update!(expires_at: 1.minute.ago)
    expired_grant = Toybaco::WidgetHandoff.find_by!(widget_session_record_id: live.id, kind: 'recovery')
    expired_grant.update!(expires_at: 1.minute.ago)
    conversation = Conversation.create!(account: @widgets[0].account, inbox: @widgets[0].inbox,
      contact: @links[0].contact, contact_inbox: @links[0])
    clear_browser_cookies
    issue(intent: SecureRandom.hex(32))
    expired = Toybaco::WidgetSessionRecord.last
    expired.update!(expires_at: 1.minute.ago)
    assert_no_difference ['ContactInbox.count', 'Contact.count', 'Conversation.count'] do
      Toybaco::WidgetSessionSweepJob.new.perform
    end
    refute Toybaco::WidgetSessionRecord.exists?(expired.id)
    refute Toybaco::WidgetHandoff.exists?(widget_session_record_id: expired.id)
    refute Toybaco::WidgetHandoff.exists?(expired_grant.id)
    assert live.reload.current?
    assert Toybaco::WidgetHandoff.exists?(bridge.id), 'An expired replay window does not remove a still-valid cookie alias'
    assert_equal @links[0].id, conversation.reload.contact_inbox_id
  end

  def test_recovery_code_cannot_be_replayed_with_another_intent
    issue
    clear_browser_cookies
    2.times do |index|
      post '/api/v1/widget/http_session/recover', params: { website_token: @widgets[0].website_token,
        handoff_code: @issued['recovery_code'], consume_intent: index.zero? ? @intent : SecureRandom.hex(32) },
        headers: headers_for, as: :json
      index.zero? ? assert_response(:success) : assert_response(:not_found)
    end
  end

  def test_handoff_consumes_once_and_original_intent_reconciles
    before = Toybaco::WidgetSessionRecord.count
    issue
    post '/api/v1/widget/http_session/handoff', params: { website_token: @widgets[0].website_token }, headers: headers_for(@proof), as: :json
    assert_response :success
    code = response.parsed_body.fetch('code')
    clear_browser_cookies
    intent = SecureRandom.hex(32)
    2.times do
      post '/api/v1/widget/http_session/consume', params: { website_token: @widgets[0].website_token,
        handoff_code: code, consume_intent: intent }, headers: headers_for, as: :json
      assert_response :success
      clear_browser_cookies
    end
    assert_equal before + 2, Toybaco::WidgetSessionRecord.count
    assert_equal 2, Toybaco::WidgetSessionRecord.where(inbox_id: @widgets[0].inbox.id).count
    post '/api/v1/widget/http_session/consume', params: { website_token: @widgets[0].website_token,
      handoff_code: code, consume_intent: SecureRandom.hex(32) }, headers: headers_for, as: :json
    assert_response :not_found
  end

  def test_handoff_wrong_inbox_and_expiry_are_rejected_before_identity_creation
    issue
    post '/api/v1/widget/http_session/handoff', params: { website_token: @widgets[0].website_token }, headers: headers_for(@proof), as: :json
    code = response.parsed_body.fetch('code')
    clear_browser_cookies
    assert_no_difference ['ContactInbox.count', 'Toybaco::WidgetSessionRecord.count'] do
      post '/api/v1/widget/http_session/consume', params: { website_token: @widgets[1].website_token,
        handoff_code: code, consume_intent: SecureRandom.hex(32) }, headers: headers_for, as: :json
      assert_response :not_found
      travel 61.seconds do
        post '/api/v1/widget/http_session/consume', params: { website_token: @widgets[0].website_token,
          handoff_code: code, consume_intent: SecureRandom.hex(32) }, headers: headers_for, as: :json
        assert_response :not_found
      end
    end
  end

  def test_handoff_into_an_existing_cookie_reconciles_the_same_record_after_cookie_response_loss
    issue
    row_id = Toybaco::WidgetSessionRecord.last.id
    post '/api/v1/widget/http_session/handoff', params: { website_token: @widgets[0].website_token }, headers: headers_for(@proof), as: :json
    assert_response :success
    code = response.parsed_body.fetch('code')
    intent = SecureRandom.hex(32)
    assert_no_difference ['Toybaco::WidgetSessionRecord.count', 'ContactInbox.count'] do
      2.times do |index|
        clear_browser_cookies if index.positive?
        post '/api/v1/widget/http_session/consume', params: { website_token: @widgets[0].website_token,
          handoff_code: code, consume_intent: intent }, headers: headers_for, as: :json
        assert_response :success
        @proof = response.parsed_body.fetch('proof')
      end
      readback
      assert_response :success
    end
    assert_equal row_id, Toybaco::WidgetSessionRecord.last.id
  end

  def test_consumed_handoff_cannot_replace_a_different_valid_browser_session
    issue
    post '/api/v1/widget/http_session/handoff', params: { website_token: @widgets[0].website_token }, headers: headers_for(@proof), as: :json
    assert_response :success
    code = response.parsed_body.fetch('code')
    intent = SecureRandom.hex(32)
    clear_browser_cookies
    post '/api/v1/widget/http_session/consume', params: { website_token: @widgets[0].website_token,
      handoff_code: code, consume_intent: intent }, headers: headers_for, as: :json
    assert_response :success
    other = ContactInbox.create!(inbox: @widgets[0].inbox,
      contact: Contact.create!(account: @widgets[0].account), source_id: SecureRandom.uuid)
    clear_browser_cookies
    issue(legacy: token_for(other), intent: SecureRandom.hex(32))
    name = Toybaco::Security::WidgetHttpSession.cookie_name(@widgets[0])
    current_cookie = cookies[name]
    post '/api/v1/widget/http_session/consume', params: { website_token: @widgets[0].website_token,
      handoff_code: code, consume_intent: intent }, headers: headers_for, as: :json
    assert_response :conflict
    assert_equal current_cookie, cookies[name]
    contact
    assert_response :success
    assert_equal other.contact_id, response.parsed_body['id']
  end

  def test_consumed_handoff_does_not_follow_its_child_into_a_new_identity
    issue
    post '/api/v1/widget/http_session/handoff', params: { website_token: @widgets[0].website_token }, headers: headers_for(@proof), as: :json
    assert_response :success
    code = response.parsed_body.fetch('code')
    intent = SecureRandom.hex(32)
    clear_browser_cookies
    post '/api/v1/widget/http_session/consume', params: { website_token: @widgets[0].website_token,
      handoff_code: code, consume_intent: intent }, headers: headers_for, as: :json
    assert_response :success
    @proof = response.parsed_body.fetch('proof')
    @links[0].contact.update!(identifier: 'before-child-switch')
    patch '/api/v1/widget/contact/set_user', params: { website_token: @widgets[0].website_token,
      identifier: 'after-child-switch' }, headers: headers_for(@proof), as: :json
    assert_response :success
    @proof = response.parsed_body.fetch('widget_auth_token')
    post '/api/v1/widget/http_session/consume', params: { website_token: @widgets[0].website_token,
      handoff_code: code, consume_intent: intent }, headers: headers_for, as: :json
    assert_response :not_found
    contact
    assert_response :success
    assert_equal 'after-child-switch', response.parsed_body['identifier']
  end

  def test_local_http_development_cookie_uses_lax_without_partitioned_or_secure_attributes
    host! 'localhost'
    https! false
    post '/api/v1/widget/http_session', params: { website_token: @widgets[0].website_token,
      legacy_token: @legacy[0], consume_intent: @intent },
      headers: { 'X-Toybaco-Widget' => '1', 'Origin' => 'http://localhost', 'Sec-Fetch-Site' => 'same-origin' }, as: :json
    assert_response :success
    line = Array(response.headers['Set-Cookie']).join(';').downcase
    assert_includes line, 'samesite=lax'
    assert_includes line, 'httponly'
    refute_includes line, 'partitioned'
    refute_match(/;\s*secure(?:;|$)/, line)
    refute_includes line, '__host-'
  end

  def test_local_http_reset_deletes_with_matching_cookie_attributes
    host! 'localhost'
    https! false
    headers = { 'X-Toybaco-Widget' => '1', 'Origin' => 'http://localhost', 'Sec-Fetch-Site' => 'same-origin' }
    post '/api/v1/widget/http_session', params: { website_token: @widgets[0].website_token,
      legacy_token: @legacy[0], consume_intent: @intent }, headers: headers, as: :json
    assert_response :success
    proof = response.parsed_body.fetch('proof')
    delete '/api/v1/widget/session', params: { website_token: @widgets[0].website_token },
      headers: headers.merge('X-Auth-Token' => proof), as: :json
    assert_response :success
    line = Array(response.headers['Set-Cookie']).join(';').downcase
    assert_includes line, 'samesite=lax'
    refute_includes line, 'partitioned'
    refute_match(/;\s*secure(?:;|$)/, line)
    refute cookies[Toybaco::Security::WidgetHttpSession.cookie_name(@widgets[0], secure: false)].present?
    contact(proof, headers: headers.merge('X-Auth-Token' => proof))
    assert_response :not_found
  end

  def test_suspended_account_is_not_disclosed_by_the_widget_cookie_or_legacy_api
    issue
    @widgets[0].account.update!(status: :suspended)
    contact(@legacy[0], headers: { 'X-Auth-Token' => @legacy[0] })
    assert_response :not_found
    readback
    assert_response :not_found
    # Application env_config is merged after request env, so scope the known
    # error renderer at its real configuration boundary, then restore diagnostics.
    with_framework_error_rendering do
      get '/widget', params: { website_token: @widgets[0].website_token, toybaco_sdk: '2' }
      assert_response :not_found
    end
  end

  def test_reset_revokes_new_cookie_and_legacy_without_deleting_history
    issue
    row = Toybaco::WidgetSessionRecord.last
    stream = Toybaco::Security::WidgetSession.new(@links[0], http_session: Toybaco::Security::WidgetHttpSession.new(row), proof: @proof)
    assert stream.current?
    assert_no_difference ['Contact.count', 'ContactInbox.count'] do
      delete '/api/v1/widget/session', params: { website_token: @widgets[0].website_token }, headers: headers_for(@proof), as: :json
      assert_response :success
      assert_equal true, response.parsed_body['session_revoked']
    end
    refute stream.current?
    contact(@proof)
    assert_response :not_found
    contact(@legacy[0])
    assert_response :not_found
  end

  def test_anonymous_bootstrap_retry_does_not_duplicate_contact
    assert_difference 'ContactInbox.count', 1 do
      issue(legacy: nil)
      clear_browser_cookies
      issue(legacy: nil)
    end
  end

  def test_bootstrap_with_foreign_legacy_proof_never_creates_anonymous_contact
    assert_no_difference 'ContactInbox.count' do
      post '/api/v1/widget/http_session', params: { website_token: @widgets[0].website_token,
        legacy_token: @legacy[1], consume_intent: @intent }, headers: headers_for, as: :json
      assert_response :not_found
    end
  end

  def test_expired_record_or_suspended_account_cannot_authenticate
    issue
    Toybaco::WidgetSessionRecord.last.update!(expires_at: 1.second.ago)
    contact
    assert_response :not_found
  end

  def stub_widget_assets
    # Asset helpers are substituted only in this native Ruby image; final Vite
    # assets and browser mounting are checked by the production-image gate.
    WidgetsController._helpers.prepend(Module.new do
      def vite_client_tag(*)
        ''
      end

      def vite_javascript_tag(*)
        ''
      end
    end)
  end

  def test_http_session_html_is_inert_before_contact_selection
    stub_widget_assets
    assert_no_difference ['Contact.count', 'ContactInbox.count'] do
      get '/widget', params: { website_token: @widgets[0].website_token, toybaco_sdk: '2' }
      assert_response :success
      assert_includes response.body, 'window.toybacoHttpSessionRequested = true'
      refute_includes response.body, @legacy[0]
      refute_includes response.body, @links[0].pubsub_token
    end
  end

  def test_legacy_html_without_parent_token_continues_the_existing_http_cookie_identity
    issue
    stub_widget_assets
    assert_no_difference ['Contact.count', 'ContactInbox.count'] do
      get '/widget', params: { website_token: @widgets[0].website_token }
      assert_response :success
      assert_includes response.body, @links[0].pubsub_token
      assert_includes response.body, 'window.toybacoHttpSessionRequested = false'
    end
    assert_equal @links[0].id, Toybaco::WidgetSessionRecord.last.contact_inbox_id
  end

  def test_identity_rebinding_expires_old_proof_and_pending_handoff
    issue
    row = Toybaco::WidgetSessionRecord.last
    session = Toybaco::Security::WidgetHttpSession.new(row)
    code = session.handoff
    stale_row = Toybaco::WidgetSessionRecord.find(row.id)
    other = ContactInbox.create!(inbox: @widgets[0].inbox,
      contact: Contact.create!(account: @widgets[0].account), source_id: SecureRandom.uuid)
    secret = session.rebind!(other)
    cookies[Toybaco::Security::WidgetHttpSession.cookie_name(@widgets[0])] = "#{row.id}.#{secret}"
    refute stale_row.current?, 'A cached record cannot claim that a newer binding is its old identity'
    refute session.valid_proof?(@proof)
    contact(session.proof)
    assert_response :success
    assert_equal other.contact_id, response.parsed_body['id']
    clear_browser_cookies
    post '/api/v1/widget/http_session/consume', params: { website_token: @widgets[0].website_token,
      handoff_code: code, consume_intent: SecureRandom.hex(32) }, headers: headers_for, as: :json
    assert_response :not_found
  end

  def test_revoke_after_header_resolution_prevents_the_business_write
    issue
    previous = @links[0].contact.name
    patch '/api/v1/widget/contact', params: { website_token: @widgets[0].website_token, name: 'Must not be saved' },
      headers: headers_for(@proof).merge('X-Synthetic-Race' => 'revoke'), as: :json
    assert_response :not_found
    assert_equal previous, @links[0].contact.reload.name
  end

  def test_rebind_after_header_resolution_cannot_write_to_either_identity
    issue
    other = ContactInbox.create!(inbox: @widgets[0].inbox,
      contact: Contact.create!(account: @widgets[0].account, name: 'Other synthetic visitor'), source_id: SecureRandom.uuid)
    before = [@links[0].contact.name, other.contact.name]
    patch '/api/v1/widget/contact', params: { website_token: @widgets[0].website_token, name: 'Must not be saved' },
      headers: headers_for(@proof).merge('X-Synthetic-Race' => 'rebind', 'X-Synthetic-Link' => other.id.to_s), as: :json
    assert_response :not_found
    assert_equal before, [@links[0].contact.reload.name, other.contact.reload.name]
  end

  def test_pending_set_user_cannot_rebind_the_new_identity_back_to_the_old_contact
    issue
    other = ContactInbox.create!(inbox: @widgets[0].inbox,
      contact: Contact.create!(account: @widgets[0].account, name: 'New identity'), source_id: SecureRandom.uuid)
    patch '/api/v1/widget/contact/set_user', params: { website_token: @widgets[0].website_token,
      identifier: 'must-not-be-bound', name: 'Must not be saved' },
      headers: headers_for(@proof).merge('X-Synthetic-Race' => 'rebind', 'X-Synthetic-Link' => other.id.to_s), as: :json
    assert_response :not_found
    assert_equal other.id, Toybaco::WidgetSessionRecord.last.contact_inbox_id
    assert_nil @links[0].contact.reload.identifier
    assert_equal 'New identity', other.contact.reload.name
  end

  def test_handoff_does_not_trust_a_cached_parent_association_after_identity_change
    issue
    session = Toybaco::Security::WidgetHttpSession.new(Toybaco::WidgetSessionRecord.last)
    code = session.handoff
    grant = Toybaco::WidgetHandoff.last
    grant.widget_session_record.contact_inbox
    other = ContactInbox.create!(inbox: @widgets[0].inbox,
      contact: Contact.create!(account: @widgets[0].account), source_id: SecureRandom.uuid)
    session.rebind!(other)
    locked_grants = Object.new
    locked_grants.define_singleton_method(:find_by!) { |*| grant }
    clear_browser_cookies
    assert_no_difference ['ContactInbox.count', 'Toybaco::WidgetSessionRecord.count'] do
      Toybaco::WidgetHandoff.stub(:find_by!, locked_grants.method(:find_by!)) do
        post '/api/v1/widget/http_session/consume', params: { website_token: @widgets[0].website_token,
          handoff_code: code, consume_intent: SecureRandom.hex(32) }, headers: headers_for, as: :json
        assert_response :not_found
      end
    end
    assert_nil grant.reload.consumed_at
  end
end

require 'action_cable/channel/test_case'

class ToybacoWidgetHttpChannelRuntimeTest < ActionCable::Channel::TestCase
  tests RoomChannel
  self.use_transactional_tests = true

  def setup
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    account = Account.create!(name: 'Synthetic HTTP Cable')
    @widget = Channel::WebWidget.create!(account: account, website_url: 'https://customer.example.test')
    Inbox.create!(account: account, channel: @widget, name: 'Synthetic Cable')
    @link = ContactInbox.create!(inbox: @widget.inbox, contact: Contact.create!(account: account), source_id: SecureRandom.uuid)
    @secret = SecureRandom.hex(32)
    @row = Toybaco::WidgetSessionRecord.create!(contact_inbox: @link, inbox_id: @link.inbox_id,
      secret_digest: Toybaco::Security::WidgetHttpSession.digest(@secret),
      link_digest: Toybaco::Security::WidgetHttpSession.link_digest(@link), bootstrap_digest: SecureRandom.hex(32),
      bootstrap_expires_at: 1.minute.from_now, rotated_at: Time.current, expires_at: 30.days.from_now)
    @proof = Toybaco::Security::WidgetHttpSession.new(@row).proof
  end

  def teardown
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  def connect_cookie(origin: 'https://www.example.com', cookie: true)
    name = Toybaco::Security::WidgetHttpSession.cookie_name(@widget)
    env = Rack::MockRequest.env_for('https://www.example.com/cable', 'HTTP_ORIGIN' => origin)
    env['HTTP_COOKIE'] = "#{name}=#{@row.id}.#{@secret}" if cookie
    stub_connection(env: env)
    connection.define_singleton_method(:close) { |**_options| @toybaco_test_closed = true }
    subscribe(pubsub_token: "tbwhttp1.#{@widget.website_token}.#{@proof}")
  end

  def test_real_room_channel_requires_cookie_proof_and_fences_revoke
    connect_cookie
    assert subscription.confirmed?
    assert_has_stream @link.pubsub_token
    Toybaco::Security::WidgetSession.revoke(@link, source_id: @link.source_id)
    refute subscription.send(:verify_toybaco_session)
    assert_no_streams
    assert connection.instance_variable_get(:@toybaco_test_closed)
  end

  # connect_cookie の stub_connection(ConnectionStub、Rails 7.2.3.2 channel/test_case.rb 50-61 行)は渡した識別子を public な
  # singleton method にするだけで、実 Connection の可視性を再現しない(以前は public な request を渡していたため、channel の
  # connection.request の欠陥を見逃した)。本番の ApplicationCable::Connection では
  # ActionCable::Connection::Base#request が private(channel から呼ぶと NoMethodError)なので、実 Connection で同じ
  # cookie + proof の購読を通す。
  def test_real_application_cable_connection_with_private_request_confirms_cookie_proof_stream
    name = Toybaco::Security::WidgetHttpSession.cookie_name(@widget)
    env = Rack::MockRequest.env_for('https://www.example.com/cable', 'HTTP_ORIGIN' => 'https://www.example.com')
    env['HTTP_COOKIE'] = "#{name}=#{@row.id}.#{@secret}"
    @connection = ApplicationCable::Connection.new(ActionCable.server, env)
    refute connection.respond_to?(:request)
    assert connection.respond_to?(:request, true)
    assert connection.respond_to?(:env)
    connection.define_singleton_method(:close) { |**_options| @toybaco_test_closed = true }
    subscribe(pubsub_token: "tbwhttp1.#{@widget.website_token}.#{@proof}")
    assert subscription.confirmed?
    assert_has_stream @link.pubsub_token
    assert_equal @link.contact, subscription.send(:current_user)
    # helper の Request は framework の private request と同じ式で同じ env から作った Request と一致する。
    built = subscription.send(:toybaco_cable_request)
    oracle = ActionDispatch::Request.new(Rails.application.env_config.merge(connection.env))
    config_keys = Rails.application.env_config.keys
    assert_includes built.cookies.keys, name
    assert_equal oracle.cookies, built.cookies
    assert_equal oracle.headers['Origin'], built.headers['Origin']
    assert_equal oracle.base_url, built.base_url
    refute_empty config_keys
    assert_equal oracle.env.slice(*config_keys), built.env.slice(*config_keys)
    Toybaco::Security::WidgetSession.revoke(@link, source_id: @link.source_id)
    refute subscription.send(:verify_toybaco_session)
    assert_no_streams
    assert connection.instance_variable_get(:@toybaco_test_closed)
  end

  def test_foreign_socket_origin_is_rejected
    connect_cookie(origin: 'https://foreign.example.test')
    assert subscription.rejected?
    assert_no_streams
  end

  def test_socket_proof_without_cookie_is_rejected
    connect_cookie(cookie: false)
    assert subscription.rejected?
    assert_no_streams
  end

  def test_socket_expiry_closes_existing_stream
    connect_cookie
    assert subscription.confirmed?
    travel 24.hours + 1.second do
      refute subscription.send(:verify_toybaco_session)
      assert_no_streams
      assert connection.instance_variable_get(:@toybaco_test_closed)
    end
  end
end

class ToybacoWidgetHttpLockOrderRuntimeTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def setup
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @account = Account.create!(name: 'Synthetic HTTP Lock Order')
    @widget = Channel::WebWidget.create!(account: @account, website_url: 'https://customer.example.test')
    Inbox.create!(account: @account, channel: @widget, name: 'Synthetic Lock Order')
    @link = ContactInbox.create!(inbox: @widget.inbox, contact: Contact.create!(account: @account), source_id: SecureRandom.uuid)
    @parent, @parent_secret = create_session
    @other, @other_secret = create_session
  end

  def teardown
    @account&.destroy!
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  def create_session(link = @link)
    secret = SecureRandom.hex(32)
    row = Toybaco::WidgetSessionRecord.create!(contact_inbox: link, inbox_id: link.inbox_id,
      secret_digest: Toybaco::Security::WidgetHttpSession.digest(secret),
      link_digest: Toybaco::Security::WidgetHttpSession.link_digest(link), bootstrap_digest: SecureRandom.hex(32),
      bootstrap_expires_at: 1.minute.from_now, rotated_at: Time.current, expires_at: 1.day.from_now)
    [row, secret]
  end

  def request_for(proof: nil)
    env = Rack::MockRequest.env_for('https://www.example.com/api/v1/widget/http_session/consume',
      'HTTP_ORIGIN' => 'https://www.example.com', 'HTTP_SEC_FETCH_SITE' => 'same-origin', 'HTTP_X_TOYBACO_WIDGET' => '1')
    env['HTTP_COOKIE'] = "#{Toybaco::Security::WidgetHttpSession.cookie_name(@widget)}=#{@other.id}.#{@other_secret}"
    env['HTTP_X_AUTH_TOKEN'] = proof if proof
    ActionDispatch::Request.new(env)
  end

  def blocking_backend_ids(pid)
    # A live lock observer must bypass the SQL query cache; otherwise its first
    # empty result can be replayed after the other backend really starts waiting.
    connection = ActiveRecord::Base.connection
    connection.uncached { connection.select_values("SELECT unnest(pg_blocking_pids(#{Integer(pid)}))").map(&:to_i) }
  end

  def test_consume_and_actual_api_fence_do_not_take_contact_lock_before_another_session_lock
    code = Toybaco::Security::WidgetHttpSession.new(@parent).handoff
    ready = Queue.new
    proceed = Queue.new
    pids = Queue.new
    workers = []
    begin_consume = Queue.new
    workers << Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.execute("SET LOCAL lock_timeout = '5s'")
          pids << [:api, connection.select_value('SELECT pg_backend_pid()').to_i]
          session = Toybaco::Security::WidgetHttpSession.new(Toybaco::WidgetSessionRecord.find(@other.id))
          Thread.current[:toybaco_widget_link_lock_fixture] = { ready: ready, continue: proceed }
          ToybacoWidgetHttpFenceHarness.new(session, @widget, request_for(proof: session.proof)).call
        ensure
          Thread.current[:toybaco_widget_link_lock_fixture] = nil
        end
      end
    end
    Timeout.timeout(8) { ready.pop }
    workers << Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.execute("SET LOCAL lock_timeout = '5s'")
          pids << [:consume, connection.select_value('SELECT pg_backend_pid()').to_i]
          begin_consume.pop
          Toybaco::Security::WidgetHttpSession.consume(request_for, @widget, code: code, intent: SecureRandom.hex(32))
        end
      end
    end
    ids = Timeout.timeout(8) { 2.times.map { pids.pop }.to_h }
    # Deliberately cache the pre-wait empty result. The actual observer must
    # still see the later lock, proving this test cannot pass on cached metadata.
    ActiveRecord::Base.connection.cache do
      assert_empty ActiveRecord::Base.connection.select_values("SELECT unnest(pg_blocking_pids(#{ids.fetch(:consume)}))")
      begin_consume << true
      Timeout.timeout(4) do
        loop do
          # Do not hide a failed worker behind an observer timeout. Propagate
          # its real exception before looking for a row-lock wait.
          unless workers[1].alive?
            workers[1].value
            flunk 'Consume completed before the expected session-row lock wait'
          end
          waiting_on = blocking_backend_ids(ids.fetch(:consume))
          break if waiting_on.include?(ids.fetch(:api))

          sleep 0.01
        end
      end
    end
    proceed << true
    assert_equal :api_completed, Timeout.timeout(8) { workers[0].value }
    result = Timeout.timeout(8) { workers[1].value }
    assert_equal @other.id, result[0].record.id
    assert result[1].nil?, 'Existing browser state is preserved without issuing a replacement session'
    assert_equal @other.id, Toybaco::WidgetHandoff.find_by!(code_digest: Toybaco::Security::WidgetHttpSession.digest(code)).consumed_session_id
  ensure
    workers&.each { |worker| worker.kill if worker.alive? }
    workers&.each(&:join)
  end

  def test_contact_merge_and_actual_widget_write_share_a_lock_before_conversation_and_link_rows
    base = Contact.create!(account: @account, name: 'Synthetic merge target')
    conversation = Conversation.create!(account: @account, inbox: @widget.inbox,
      contact: @link.contact, contact_inbox: @link)
    ready = Queue.new
    proceed = Queue.new
    pids = Queue.new
    workers = []
    workers << Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.execute("SET LOCAL lock_timeout = '5s'")
          pids << [:merge, connection.select_value('SELECT pg_backend_pid()').to_i]
          Thread.current[:toybaco_widget_merge_pause_fixture] = { ready: ready, continue: proceed }
          ContactMergeAction.new(account: @account, base_contact: base, mergee_contact: @link.contact).perform
        ensure
          Thread.current[:toybaco_widget_merge_pause_fixture] = nil
        end
      end
    end
    Timeout.timeout(8) { ready.pop }
    workers << Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.execute("SET LOCAL lock_timeout = '5s'")
          pids << [:api, connection.select_value('SELECT pg_backend_pid()').to_i]
          session = Toybaco::Security::WidgetHttpSession.new(Toybaco::WidgetSessionRecord.find(@other.id))
          ToybacoWidgetHttpFenceHarness.new(session, @widget, request_for(proof: session.proof)).call do
            Conversation.find(conversation.id).update!(additional_attributes: { synthetic: 'preserved' })
          end
        end
      end
    end
    ids = Timeout.timeout(8) { 2.times.map { pids.pop }.to_h }
    Timeout.timeout(4) do
      loop do
        blockers = blocking_backend_ids(ids.fetch(:api))
        break if blockers.include?(ids.fetch(:merge))

        sleep 0.01
      end
    end
    proceed << true
    assert_equal base.id, Timeout.timeout(8) { workers[0].value.id }
    assert_equal true, Timeout.timeout(8) { workers[1].value }
    assert_equal base.id, conversation.reload.contact_id
    assert_equal @link.id, conversation.contact_inbox_id
    assert_equal 'preserved', conversation.additional_attributes.fetch('synthetic')
  ensure
    workers&.each { |worker| worker.kill if worker.alive? }
    workers&.each(&:join)
  end

  def identity_controller(klass, action, row)
    session = Toybaco::Security::WidgetHttpSession.new(Toybaco::WidgetSessionRecord.find(row.id))
    controller = klass.new
    controller.action_name = action
    controller.instance_variable_set(:@_request, request_for(proof: session.proof))
    controller.instance_variable_set(:@toybaco_http_session, session)
    controller.instance_variable_set(:@web_widget, @widget)
    controller.instance_variable_set(:@contact_inbox, session.record.contact_inbox)
    controller.instance_variable_set(:@contact, session.record.contact_inbox.contact)
    controller.instance_variable_set(:@auth_token_params, session.claims)
    controller
  end

  def test_conversation_create_and_message_email_update_do_not_upgrade_shared_locks_during_merge
    base = Contact.create!(account: @account, email: 'synthetic-lock-target@example.test')
    second_link = ContactInbox.create!(inbox: @widget.inbox,
      contact: Contact.create!(account: @account), source_id: SecureRandom.uuid)
    second_row, = create_session(second_link)
    ready = Queue.new
    proceed = Queue.new
    pids = Queue.new
    workers = []
    specs = [[Api::V1::Widget::ConversationsController, 'create', @parent],
             [Api::V1::Widget::MessagesController, 'update', second_row]]
    specs.each_with_index do |(klass, action, row), index|
      Timeout.timeout(8) { ready.pop } if index == 1
      workers << Thread.new do
        Thread.current.report_on_exception = false
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.transaction do
            connection.execute("SET LOCAL lock_timeout = '5s'")
            pids << [index, connection.select_value('SELECT pg_backend_pid()').to_i]
            controller = identity_controller(klass, action, row)
            controller.send(:with_toybaco_http_session_fence) do
              if index.zero?
                ready << true
                proceed.pop
              end
              ContactIdentifyAction.new(contact: controller.instance_variable_get(:@contact),
                params: { email: base.email }, retain_original_contact_name: true).perform
            end
          end
        end
      end
    end
    ids = Timeout.timeout(8) { 2.times.map { pids.pop }.to_h }
    Timeout.timeout(4) do
      loop do
        blockers = blocking_backend_ids(ids.fetch(1))
        break if blockers.include?(ids.fetch(0))

        sleep 0.01
      end
    end
    proceed << true
    assert_equal base.id, Timeout.timeout(8) { workers[0].value.id }
    assert_equal base.id, Timeout.timeout(8) { workers[1].value.id }
    assert_equal base.id, @link.reload.contact_id
    assert_equal base.id, second_link.reload.contact_id
    assert @parent.reload.current?
    assert second_row.reload.current?
  ensure
    workers&.each { |worker| worker.kill if worker.alive? }
    workers&.each(&:join)
  end

  def test_real_contact_merge_notifies_the_preserved_widget_stream_only_after_commit
    original_contact = @link.contact
    base = Contact.create!(account: @account, name: 'Synthetic stream merge target')
    notices = []
    broadcast = lambda do |stream, payload|
      notices << [stream, payload] if payload[:event] == 'toybaco.widget.identity-changed'
    end
    ActionCable.server.stub(:broadcast, broadcast) do
      ActiveRecord::Base.transaction do
        ContactMergeAction.new(account: @account, base_contact: base, mergee_contact: original_contact).perform
        assert_empty notices, 'A not-yet-committed identity cannot be announced'
        raise ActiveRecord::Rollback
      end
      assert_empty notices, 'A rolled-back merge cannot announce a new identity'
      assert_equal original_contact.id, @link.reload.contact_id
      ContactMergeAction.new(account: @account, base_contact: base, mergee_contact: original_contact.reload).perform
    end
    assert_equal [[@link.pubsub_token, { event: 'toybaco.widget.identity-changed', data: {} }]], notices
    assert_equal base.id, @link.reload.contact_id
    assert @parent.reload.current?
  end
end
