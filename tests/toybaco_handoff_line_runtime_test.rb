# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require 'ostruct'
require Rails.root.join('lib/toybaco/connections/handoff/issue')
require Rails.root.join('lib/toybaco/connections/handoff/verification')
require Rails.root.join('lib/toybaco/connections/handoff/line_presentation')
require Rails.root.join('lib/toybaco/growth/onboarding')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoHandoffLineRuntimeTest < ActionDispatch::IntegrationTest
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true
  Handoff = Toybaco::Connections::Handoff
  FIELDS = { 'line_channel_id' => '1234567890', 'line_channel_secret' => 'a' * 32, 'line_channel_token' => 'fixtureLINE+/' * 20 }.freeze
  NOW = Time.utc(2026, 9, 19, 6)

  def setup
    travel_to NOW
    @adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @account = create(:account)
    @owner = create(:user, :administrator, account: @account)
    @helper = create(:user, email: "line-helper-#{SecureRandom.uuid}@example.test")
    @nonce = SecureRandom.hex(32)
    @api_calls = []
    @api = Object.new
    @api.define_singleton_method(:verify!) { |**| true }
    @old_frontend = ENV['FRONTEND_URL']
    ENV['FRONTEND_URL'] = 'https://app.staging.toybaco.jp'
    terms = Toybaco::PlanCatalog.default.definition('free', '2026-09-18.1')
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: nil))
  end

  def teardown
    @old_frontend ? ENV['FRONTEND_URL'] = @old_frontend : ENV.delete('FRONTEND_URL')
    travel_back
    ActiveJob::Base.queue_adapter = @adapter
    Current.reset
  end

  def enabled(&block)
    Handoff::Access.stub(:enabled?, true, &block)
  end

  def issue(provider: 'line', inbox_id: nil)
    enabled do
      @record, @token = Handoff::Issue.new(@account, @owner).create!(request_id: SecureRandom.uuid,
                       recipient: @helper.email, provider: provider, inbox_id: inbox_id)
    end
    @record
  end

  def claim(**options)
    issue(**options)
    enabled { Handoff::Verification.new(@record).login!(token: @token, browser_nonce: @nonce, user: @helper) }
  end

  def save(fields: FIELDS, api: @api, nonce: @nonce)
    enabled do
      Handoff::LineSetup.new(@record, api: api).save!(browser_nonce: nonce, fields: fields.dup)
    end
  end

  def existing(account: @account, id: FIELDS['line_channel_id'])
    channel = Channel::Line.new(FIELDS.merge('account' => account, 'line_channel_id' => id))
    assert channel.valid?, channel.errors.details.inspect
    channel.save!
    account.inboxes.create!(channel: channel, name: 'LINE fixture')
  end

  def with_user(user, &block)
    Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: user), &block)
  end

  def send_json(path, body, user: nil, origin: 'https://app.staging.toybaco.jp')
    host! 'app.staging.toybaco.jp'
    https!
    enabled { with_user(user) { post path, params: body, as: :json, headers: { 'Origin' => origin, 'Sec-Fetch-Site' => 'same-origin' } } }
  end

  def test_encrypted_native_line_storage_and_one_use_receipt_without_store_membership
    assert Chatwoot.encryption_configured?, 'This test must boot with the three fixture encryption keys'
    claim
    calls = []
    api = Object.new
    api.define_singleton_method(:verify!) { |**args| calls << args }
    inbox = save(api: api)
    assert_equal @account.id, inbox.account_id
    assert_equal 'Channel::Line', inbox.channel_type
    assert_equal FIELDS['line_channel_secret'], inbox.channel.reload.line_channel_secret
    assert_equal FIELDS['line_channel_token'], inbox.channel.line_channel_token
    raw = Channel::Line.connection.select_one("SELECT line_channel_secret, line_channel_token FROM channel_line WHERE id = #{inbox.channel.id.to_i}")
    FIELDS.values_at('line_channel_secret', 'line_channel_token').each { |value| refute_includes raw.to_json, value }
    assert_equal 1, calls.length
    assert_equal 'completed', @record.reload.state
    assert_equal inbox.id, @record.result_inbox_id
    assert_nil @account.account_users.find_by(user_id: @helper.id)
    assert_raises(Handoff::Forbidden) { save(api: api) }
    assert_equal 1, calls.length
    enabled do
      receipt = Handoff::LinePresentation.read(@record)
      assert receipt[:settings_saved]
      refute receipt[:receipt_verified]
      assert_equal "https://app.staging.toybaco.jp/webhooks/line/#{FIELDS['line_channel_id']}", receipt[:webhook_url]
      refute_includes receipt.to_json, FIELDS['line_channel_token']
    end
  end

  def test_plaintext_legacy_line_can_be_read_then_updated_to_native_ciphertext
    inbox = existing
    channel = inbox.channel
    ActiveRecord::Encryption.without_encryption do
      channel.update_columns(line_channel_secret: FIELDS['line_channel_secret'], line_channel_token: FIELDS['line_channel_token'])
    end
    channel.reload
    refute channel.encrypted_attribute?(:line_channel_token)
    assert_equal FIELDS['line_channel_token'], channel.line_channel_token
    assert_equal FIELDS['line_channel_secret'], channel.line_channel_secret
    claim(inbox_id: inbox.id)
    save(fields: FIELDS.merge('line_channel_token' => 'updatedLegacyToken+' * 20))
    current = Channel::Line.find(channel.id)
    assert current.encrypted_attribute?(:line_channel_token)
    assert current.encrypted_attribute?(:line_channel_secret)
    assert_equal 'updatedLegacyToken+' * 20, current.line_channel_token
    assert_equal inbox.id, @record.reload.result_inbox_id
  end

  def test_native_client_receives_decrypted_credentials_from_a_fresh_model
    inbox = existing
    captured = nil
    factory = lambda do |&configure|
      captured = OpenStruct.new
      configure.call(captured)
      captured
    end
    Line::Bot::Client.stub(:new, factory) { Channel::Line.find(inbox.channel_id).client }
    assert_equal FIELDS['line_channel_id'], captured.channel_id
    assert_equal FIELDS['line_channel_secret'], captured.channel_secret
    assert_equal FIELDS['line_channel_token'], captured.channel_token
  end

  def test_native_credential_limit_matches_the_public_input_boundary
    channel = Channel::Line.new(FIELDS.merge('account' => @account, 'line_channel_token' => 'x' * 4096))
    assert channel.valid?, channel.errors.details.inspect
    channel.line_channel_token += 'x'
    refute channel.valid?
    assert channel.errors.of_kind?(:line_channel_token, :too_long)
  end

  def test_existing_target_only_updates_named_native_channel
    inbox = existing
    claim(inbox_id: inbox.id)
    saved = save(fields: FIELDS.merge('line_channel_token' => 'changed-token+' * 20))
    assert_equal inbox.id, saved.id
    assert_equal 1, @account.inboxes.count
    assert_equal 'changed-token+' * 20, inbox.channel.reload.line_channel_token
  end

  def test_existing_target_cannot_be_replaced_by_another_line_account
    inbox = existing
    claim(inbox_id: inbox.id)
    assert_raises(Handoff::Forbidden) { save(fields: FIELDS.merge('line_channel_id' => '9999999999')) }
    assert_equal FIELDS['line_channel_token'], inbox.channel.reload.line_channel_token
    assert_equal 'claimed', @record.reload.state
  end

  def test_unscoped_existing_channel_is_not_modified_even_in_same_store
    inbox = existing
    claim
    assert_raises(Handoff::Invalid) { save }
    assert_equal FIELDS['line_channel_token'], inbox.channel.reload.line_channel_token
    assert_equal 1, @account.inboxes.count
    inbox.channel.update!(line_channel_id: '9999999999')
    foreign = existing(account: create(:account))
    assert_raises(Handoff::Invalid) { save }
    assert_equal FIELDS['line_channel_token'], foreign.channel.reload.line_channel_token
  end

  def test_plan_limit_prevents_new_inbox_and_leaves_claim_available
    2.times { create(:inbox, account: @account) }
    claim
    assert_raises(Handoff::Limited) { save }
    assert_equal 2, @account.inboxes.count
    assert_equal 0, Channel::Line.where(account: @account).count
    assert_equal 'claimed', @record.reload.state
  end

  def test_invalid_fields_are_rejected_before_external_verification
    claim
    api = Object.new
    api.define_singleton_method(:verify!) { |**| raise 'unexpected external call' }
    [FIELDS.merge('extra' => 'x'), FIELDS.merge('line_channel_id' => 1234567890),
     FIELDS.merge('line_channel_id' => '../123'), FIELDS.merge('line_channel_secret' => 'not-secret'),
     FIELDS.merge('line_channel_token' => 'short')].each do |fields|
      assert_raises(Handoff::Invalid) { save(fields: fields, api: api) }
    end
    assert_equal 0, @account.inboxes.count
  end

  def test_failed_token_check_leaves_native_database_unchanged
    claim
    api = Object.new
    api.define_singleton_method(:verify!) { |**| raise Toybaco::Connections::LineSetupApi::Error }
    assert_raises(Toybaco::Connections::LineSetupApi::Error) { save(api: api) }
    assert_equal 0, @account.inboxes.count
    assert_equal 0, Channel::Line.where(account: @account).count
    assert_equal 'claimed', @record.reload.state
  end

  def test_expiry_during_verification_rolls_back_inbox_and_credentials
    claim
    api = Object.new
    test_case = self
    deadline = @record.expires_at
    api.define_singleton_method(:verify!) { |**| test_case.travel_to(deadline + 1.second) }
    assert_raises(Handoff::Forbidden) { save(api: api) }
    assert_equal 0, @account.inboxes.count
    assert_equal 0, Channel::Line.where(account: @account).count
    assert_equal 'claimed', @record.reload.state
  end

  def test_feature_and_native_encryption_are_required_before_any_save
    claim
    Handoff::Access.stub(:enabled?, false) { refute Handoff::LineSetup.available? }
    enabled do
      Chatwoot.stub(:encryption_configured?, false) do
        refute Handoff::LineSetup.available?
        assert_raises(Handoff::Unavailable) { Handoff::LineSetup.new(@record, api: @api).save!(browser_nonce: @nonce, fields: FIELDS) }
      end
    end
    assert_equal 0, @account.inboxes.count
  end

  def test_wrong_browser_creator_permission_loss_and_wrong_provider_cannot_save
    claim
    assert_raises(Handoff::Forbidden) { save(nonce: SecureRandom.hex(32)) }
    @account.account_users.find_by!(user_id: @owner.id).update!(role: 0)
    assert_raises(Handoff::Forbidden) { save }
    @account.account_users.find_by!(user_id: @owner.id).update!(role: 1)
    claim(provider: 'website')
    assert_raises(Handoff::Forbidden) { save }
    assert_equal 0, @account.inboxes.count
  end

  def test_only_current_creator_recovers_issued_link_after_reload
    issue
    enabled do
      assert_equal @token, Handoff::Issue.new(@account, @owner).link_for(@record)
      another = create(:user, :administrator, account: @account)
      assert_nil Handoff::Issue.new(@account, another).link_for(@record)
      Handoff::Verification.new(@record).login!(token: @token, browser_nonce: @nonce, user: @helper)
      assert_nil Handoff::Issue.new(@account, @owner).link_for(@record)
    end
  end

  def test_pages_reveal_store_only_to_owner_or_recipient_proof
    issue
    host! 'app.staging.toybaco.jp'
    https!
    enabled { get "/toybaco/connections/help/#{@record.public_id}" }
    assert_response :success
    refute_includes response.body, @account.name
    refute_includes response.body, @helper.email
    assert_includes response.headers['Content-Security-Policy'], "frame-ancestors 'none'"
    assert_equal 'no-store', response.headers['Cache-Control']
    enabled { with_user(@helper) { get '/toybaco/connections/handoff', params: { account_id: @account.id } } }
    assert_response :forbidden
    enabled { with_user(@owner) { get '/toybaco/connections/handoff', params: { account_id: @account.id } } }
    assert_response :success
    assert_includes response.body, '依頼リンクを作成'
    refute_includes response.body, @token
  end

  def test_actual_routes_bind_cookie_require_origin_and_never_return_secrets
    issue
    base = "/toybaco/connections/help/#{@record.public_id}"
    send_json("#{base}/open", { link_secret: @token })
    assert_response :success
    send_json("#{base}/login", { link_secret: @token }, user: @helper)
    assert_response :success
    send_json("#{base}/line", { fields: FIELDS }, origin: 'https://evil.example')
    assert_response :forbidden
    Toybaco::Connections::LineSetupApi.stub(:new, @api) do
      send_json("#{base}/line", { fields: FIELDS })
      assert_response :success
      assert response.parsed_body['settings_saved']
      refute response.parsed_body['receipt_verified']
      refute_includes response.body, FIELDS['line_channel_token']
      refute_includes response.body, FIELDS['line_channel_secret']
    end
    enabled { get "#{base}/line" }
    assert_response :success
    assert response.parsed_body['settings_saved']
    reset!
    host! 'app.staging.toybaco.jp'
    https!
    enabled { get "#{base}/line" }
    assert_response :forbidden
  end

  def test_wrong_code_returns_remaining_attempts_without_revoking_link
    issue
    base = "/toybaco/connections/help/#{@record.public_id}"
    send_json("#{base}/open", { link_secret: @token })
    send_json("#{base}/code", { link_secret: @token })
    assert_response :accepted
    send_json("#{base}/verify", { link_secret: @token, verification_code: 'wrong' })
    assert_response :unprocessable_entity
    assert_equal 4, response.parsed_body['verification_remaining']
    assert_equal 'issued', @record.reload.state
    code = Handoff::Access.decode(@record, "code:#{@record.verification_revision}", @record.encrypted_verification)
    send_json("#{base}/verify", { link_secret: @token, verification_code: code })
    assert_response :success
    assert_equal 'claimed', @record.reload.state
  end

  def test_tour_exposes_handoff_only_to_administrator_when_native_encryption_is_ready
    enabled do
      assert Toybaco::Growth::Onboarding.new(@account, @owner).read['handoff_line_available']
      member = create(:user, account: @account)
      refute Toybaco::Growth::Onboarding.new(@account, member).read['handoff_line_available']
      Chatwoot.stub(:encryption_configured?, false) do
        refute Toybaco::Growth::Onboarding.new(@account, @owner).read['handoff_line_available']
      end
    end
  end
end
