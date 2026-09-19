# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require 'ostruct'
require Rails.root.join('lib/toybaco/connections/handoff/issue')
require Rails.root.join('lib/toybaco/connections/handoff/verification')
require Rails.root.join('lib/toybaco/connections/handoff/delivery')
require Rails.root.join('lib/toybaco/connections/handoff/completion')
require Rails.root.join('lib/toybaco/connections/handoff/presentation')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoConnectionHandoffRuntimeTest < ActionDispatch::IntegrationTest
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true
  Handoff = Toybaco::Connections::Handoff
  NOW = Time.utc(2026, 9, 19, 6)

  def setup
    travel_to NOW
    @adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @account = create(:account)
    @owner = create(:user, :administrator, account: @account)
    @helper = create(:user, email: "handoff-helper-#{SecureRandom.uuid}@example.test")
    @nonce = SecureRandom.hex(32)
    @request_id = SecureRandom.uuid
    @old_sender = ENV['MAILER_SENDER_EMAIL']
    ENV['MAILER_SENDER_EMAIL'] = 'トイバコ <no-reply@toybaco.jp>'
    @old_frontend = ENV['FRONTEND_URL']
    ENV['FRONTEND_URL'] = 'https://app.staging.toybaco.jp'
  end

  def teardown
    @old_sender ? ENV['MAILER_SENDER_EMAIL'] = @old_sender : ENV.delete('MAILER_SENDER_EMAIL')
    @old_frontend ? ENV['FRONTEND_URL'] = @old_frontend : ENV.delete('FRONTEND_URL')
    travel_back
    ActiveJob::Base.queue_adapter = @adapter
    Current.reset
  end

  def enabled(&block)
    Handoff::Access.stub(:enabled?, true, &block)
  end

  def issue(request_id: @request_id, recipient: @helper.email, provider: 'line', inbox_id: nil)
    enabled { Handoff::Issue.new(@account, @owner).create!(request_id: request_id, recipient: recipient, provider: provider, inbox_id: inbox_id) }
  end

  def requested
    @record, @token = issue
    enabled { Handoff::Verification.new(@record).request!(token: @token, browser_nonce: @nonce) }
    @code = Handoff::Access.decode(@record, "code:#{@record.verification_revision}", @record.encrypted_verification)
    [@record, @token]
  end

  def claimed(provider: 'line', inbox_id: nil)
    @record, @token = issue(provider: provider, inbox_id: inbox_id)
    enabled { Handoff::Verification.new(@record).login!(token: @token, browser_nonce: @nonce, user: @helper) }
    @record
  end

  def with_user(user, &block)
    Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: user), &block)
  end

  def json_post(url, body, user: nil, origin: 'https://app.staging.toybaco.jp')
    host! 'app.staging.toybaco.jp'
    https!
    enabled { with_user(user) { post url, params: body, as: :json, headers: { 'Origin' => origin, 'Sec-Fetch-Site' => 'same-origin' } } }
  end

  def test_recipient_address_requires_a_deliverable_ascii_mailbox
    ['宛先@example.test', 'recipient\n@example.test', 'no-address', ''].each do |recipient|
      assert_raises(Handoff::Invalid) { issue(recipient: recipient) }
    end
    assert_equal 0, Toybaco::ConnectionHandoff.where(account: @account).count
  end

  def test_creation_is_scoped_encrypted_one_day_and_idempotently_recoverable
    record, token = issue
    assert_equal NOW + 24.hours, record.expires_at
    assert_equal 'line:new', record.target_key
    assert_equal 'issued', record.state
    assert_equal @helper.email.downcase, Handoff::Access.decode(record, 'recipient', record.encrypted_recipient)
    refute_includes record.attributes.to_json, token
    refute_includes record.attributes.to_json, @helper.email
    assert_equal [record.id, token], issue.then { |row, secret| [row.id, secret] }
    assert_equal 1, Toybaco::ConnectionHandoff.where(account: @account).count
    assert_raises(Handoff::Invalid) { issue(recipient: 'different@example.test') }
    value = Handoff::Presentation.owner(record, token: token)
    assert_equal token, URI(value[:url]).fragment
    assert_nil URI(value[:url]).query
  end

  def test_regeneration_revokes_old_link_and_existing_claim_without_extending_the_old_deadline
    claimed
    old = @record
    fresh, = issue(request_id: SecureRandom.uuid)
    assert_equal 'revoked', old.reload.state
    assert_nil old.claim_digest
    assert_nil old.encrypted_token
    assert_equal NOW + 24.hours, old.expires_at
    assert_equal 'issued', fresh.state
    enabled { assert_raises(Handoff::Forbidden) { Handoff::Access.claim!(old, @nonce) } }
  end

  def test_permissions_and_target_are_rechecked_without_giving_the_recipient_membership
    record, = issue
    refute @account.account_users.exists?(user_id: @helper.id)
    @account.account_users.where(user_id: @owner.id).update_all(role: 0)
    enabled { assert_raises(Handoff::Forbidden) { Handoff::Access.current!(record) } }
    assert_raises(Handoff::Forbidden) { issue(request_id: SecureRandom.uuid) }
    assert_nil record.reload.claimed_at
  end

  def test_foreign_and_wrong_channel_targets_are_rejected_before_a_request_is_created
    foreign = create(:inbox)
    wrong = create(:inbox, account: @account)
    assert_raises(Handoff::Forbidden) { issue(inbox_id: foreign.id) }
    assert_raises(Handoff::Forbidden) { issue(provider: 'line', inbox_id: wrong.id) }
    assert_raises(Handoff::Invalid) { issue(inbox_id: wrong.id.to_s) }
    assert_equal 0, Toybaco::ConnectionHandoff.where(account: @account).count
  end

  def test_issue_limit_cannot_be_bypassed_by_revocation_or_a_changed_request_identifier
    10.times { issue(request_id: SecureRandom.uuid) }
    assert_raises(Handoff::Limited) { issue(request_id: SecureRandom.uuid) }
    assert_equal 10, Toybaco::ConnectionHandoff.where(account: @account).count
    assert_equal 1, Toybaco::ConnectionHandoff.where(account: @account, state: 'issued').count
  end

  def test_code_requires_matching_browser_and_failed_attempts_are_committed
    requested
    enabled do
      assert_raises(Handoff::Forbidden) { Handoff::Verification.new(@record).verify!(token: @token, browser_nonce: SecureRandom.hex(32), code: @code) }
      assert_equal 0, @record.reload.verification_attempts
      wrong = @code == '000000' ? '111111' : '000000'
      5.times do |index|
        assert_raises(Handoff::Forbidden) { Handoff::Verification.new(@record).verify!(token: @token, browser_nonce: @nonce, code: wrong) }
        assert_equal index + 1, @record.reload.verification_attempts
      end
      assert_raises(Handoff::Limited) { Handoff::Verification.new(@record).verify!(token: @token, browser_nonce: @nonce, code: @code) }
    end
    assert_equal 'issued', @record.reload.state
  end

  def test_successful_code_consumes_the_link_and_permits_only_the_claimed_browser
    requested
    enabled do
      Handoff::Verification.new(@record).verify!(token: @token, browser_nonce: @nonce, code: @code)
      Handoff::Access.claim!(@record.reload, @nonce)
      assert_raises(Handoff::Forbidden) { Handoff::Access.claim!(@record, SecureRandom.hex(32)) }
      assert_raises(Handoff::Forbidden) { Handoff::Verification.new(@record).verify!(token: @token, browser_nonce: @nonce, code: @code) }
    end
    assert_equal 'claimed', @record.state
    assert_nil @record.encrypted_recipient
    assert_nil @record.token_digest
    assert_nil @record.encrypted_verification
    refute @account.account_users.exists?(user_id: @helper.id)
  end

  def test_email_confirmation_expiry_resend_cooldown_and_total_send_limit
    requested
    service = Handoff::Verification.new(@record)
    enabled do
      assert_raises(Handoff::Limited) { service.request!(token: @token, browser_nonce: @nonce) }
      travel 10.minutes
      assert_raises(Handoff::Forbidden) { service.verify!(token: @token, browser_nonce: @nonce, code: @code) }
      SecureRandom.stub(:random_number, (@code.to_i + 1) % 1_000_000) { service.request!(token: @token, browser_nonce: @nonce) }
      assert_equal 2, @record.reload.verification_send_count
      assert_raises(Handoff::Forbidden) { service.verify!(token: @token, browser_nonce: @nonce, code: @code) }
      travel 61.seconds
      service.request!(token: @token, browser_nonce: @nonce)
      travel 61.seconds
      assert_raises(Handoff::Limited) { service.request!(token: @token, browser_nonce: @nonce) }
    end
    assert_equal 3, @record.reload.verification_send_count
  end

  def test_verified_login_must_match_the_named_recipient
    record, token = issue
    enabled do
      assert_raises(Handoff::Forbidden) { Handoff::Verification.new(record).login!(token: token, browser_nonce: @nonce, user: @owner) }
      Handoff::Verification.new(record).login!(token: token, browser_nonce: @nonce, user: @helper)
      assert_raises(Handoff::Forbidden) { Handoff::Verification.new(record).login!(token: token, browser_nonce: @nonce, user: @helper) }
    end
    assert_equal 'claimed', record.reload.state
    assert_equal 0, record.verification_send_count
  end

  def test_revocation_expiry_and_suspension_stop_claimed_access
    claimed
    enabled do
      travel 24.hours
      assert_raises(Handoff::Forbidden) { Handoff::Access.claim!(@record, @nonce) }
      travel_to NOW
      @account.update!(status: :suspended)
      assert_raises(Handoff::Forbidden) { Handoff::Access.claim!(@record, @nonce) }
      @account.update!(status: :active)
      Handoff::Issue.new(@account, @owner).revoke!(@record)
      assert_raises(Handoff::Forbidden) { Handoff::Access.claim!(@record.reload, @nonce) }
    end
  end

  def test_queue_failure_keeps_only_a_durable_encrypted_challenge_for_recovery
    record, token = issue
    enabled do
      Toybaco::ConnectionHandoffMailJob.stub(:perform_later, ->(*) { raise IOError, 'queue fixture failure' }) do
        Handoff::Verification.new(record).request!(token: token, browser_nonce: @nonce)
      end
      assert_equal 'queued', record.reload.delivery_state
      assert record.encrypted_verification
      assert_enqueued_with(job: Toybaco::ConnectionHandoffMailJob, args: [record.id, record.verification_revision]) do
        Toybaco::ConnectionHandoffSweepJob.perform_now
      end
    end
  end

  def test_verification_mail_is_attempted_once_and_never_includes_the_link_or_customer_content
    requested
    mail = Toybaco::ConnectionHandoffMailer.verification(@helper.email, @code)
    assert_equal [@helper.email], mail.to
    assert_includes mail.body.decoded, @code
    refute_includes mail.body.decoded, @token
    refute_includes mail.body.decoded, @account.id.to_s + '/app'
    attempts = 0
    delivery = OpenStruct.new
    delivery.define_singleton_method(:deliver_now) { attempts += 1 }
    enabled do
      Toybaco::ConnectionHandoffMailer.stub(:verification, ->(recipient, code) { assert_equal @helper.email, recipient; assert_equal @code, code; delivery }) do
        2.times { Handoff::Delivery.new(@record, @record.verification_revision).perform }
      end
    end
    assert_equal 1, attempts
    assert_equal 'attempted', @record.reload.delivery_state
    assert_nil @record.encrypted_verification
  end

  def test_unknown_smtp_result_is_not_automatically_resent
    requested
    attempts = 0
    failing = Object.new
    failing.define_singleton_method(:deliver_now) { attempts += 1; raise IOError, 'fixture unknown SMTP outcome' }
    enabled do
      Toybaco::ConnectionHandoffMailer.stub(:verification, failing) do
        2.times { Handoff::Delivery.new(@record, @record.verification_revision).perform }
      end
      Toybaco::ConnectionHandoffSweepJob.perform_now
    end
    assert_equal 1, attempts
    assert_equal 'uncertain', @record.reload.delivery_state
    assert_nil @record.encrypted_verification
  end

  def test_old_queued_code_cannot_send_after_resend_or_permission_loss
    requested
    revision = @record.verification_revision
    travel 61.seconds
    enabled do
      Handoff::Verification.new(@record).request!(token: @token, browser_nonce: @nonce)
      Toybaco::ConnectionHandoffMailer.stub(:verification, ->(*) { flunk 'No mail may be constructed' }) do
        Handoff::Delivery.new(@record, revision).perform
        @account.account_users.where(user_id: @owner.id).delete_all
        Handoff::Delivery.new(@record, @record.verification_revision).perform
      end
    end
    assert_equal 'cancelled', @record.reload.delivery_state
    assert_nil @record.encrypted_verification
  end

  def test_encryption_is_bound_to_each_request_and_purpose
    record, = issue
    other, = issue(request_id: SecureRandom.uuid, provider: 'website')
    assert_raises(Handoff::Forbidden) { Handoff::Access.decode(other, 'recipient', record.encrypted_recipient) }
    assert_raises(Handoff::Forbidden) { Handoff::Access.decode(record, 'link', record.encrypted_recipient) }
  end

  def test_completion_binds_the_native_inbox_and_does_not_allow_a_second_operation
    claimed(provider: 'website')
    enabled do
      inbox = Handoff::Completion.new(@record).commit!(browser_nonce: @nonce) { create(:inbox, account: @account) }
      assert_equal inbox.id, @record.reload.result_inbox_id
      assert_equal 'completed', @record.state
      Handoff::Access.receipt!(@record, @nonce)
      assert_raises(Handoff::Forbidden) { Handoff::Completion.new(@record).commit!(browser_nonce: @nonce) { flunk 'Must not run twice' } }
      refute @account.account_users.exists?(user_id: @helper.id)
    end
  end

  def test_wrong_store_or_expiry_during_completion_rolls_back_all_native_changes
    claimed(provider: 'website')
    other = create(:account)
    enabled do
      assert_no_difference('Inbox.count') do
        assert_raises(Handoff::Forbidden) { Handoff::Completion.new(@record).commit!(browser_nonce: @nonce) { create(:inbox, account: other) } }
      end
      assert_no_difference('Inbox.count') do
        assert_raises(Handoff::Forbidden) do
          Handoff::Completion.new(@record).commit!(browser_nonce: @nonce) do
            inbox = create(:inbox, account: @account)
            travel 24.hours
            inbox
          end
        end
      end
    end
    assert_equal 'claimed', @record.reload.state
  end

  def test_sweep_purges_expired_claim_material_and_never_reopens_a_link
    claimed
    travel 24.hours
    enabled { Toybaco::ConnectionHandoffSweepJob.perform_now }
    assert_nil @record.reload.claim_digest
    assert_nil @record.encrypted_recipient
    assert_nil @record.encrypted_token
    assert_equal 'expired', Handoff::Presentation.owner(@record)[:state]
    assert_equal [@record.id, nil], issue.then { |row, token| [row.id, token] }
  end

  def test_disabled_rollout_blocks_issue_claim_and_delivery_without_mailing
    requested
    Handoff::Access.stub(:enabled?, false) do
      assert_raises(Handoff::Unavailable) do
        Handoff::Issue.new(@account, @owner).create!(request_id: SecureRandom.uuid, recipient: @helper.email, provider: 'website')
      end
      assert_raises(Handoff::Unavailable) { Handoff::Verification.new(@record).login!(token: @token, browser_nonce: @nonce, user: @helper) }
      Toybaco::ConnectionHandoffMailer.stub(:verification, ->(*) { flunk 'Rollout is closed' }) do
        Handoff::Delivery.new(@record, @record.verification_revision).perform
      end
    end
    assert_equal 'issued', @record.reload.state
    assert_equal 'queued', @record.delivery_state
  end

  def test_existing_target_cannot_be_replaced_with_another_inbox_in_the_same_store
    inbox = create(:inbox, account: @account)
    claimed(provider: 'website', inbox_id: inbox.id)
    enabled do
      assert_no_difference('Inbox.count') do
        assert_raises(Handoff::Forbidden) { Handoff::Completion.new(@record).commit!(browser_nonce: @nonce) { create(:inbox, account: @account) } }
      end
      assert_equal inbox, Handoff::Completion.new(@record).commit!(browser_nonce: @nonce) { inbox }
    end
    assert_equal inbox.id, @record.reload.result_inbox_id
  end

  def test_copied_code_ciphertext_is_cancelled_without_mail_construction
    requested
    original = @record
    @record, @token = issue(request_id: SecureRandom.uuid, provider: 'website')
    enabled do
      Handoff::Verification.new(@record).request!(token: @token, browser_nonce: @nonce)
      @record.update!(encrypted_verification: original.encrypted_verification)
      Toybaco::ConnectionHandoffMailer.stub(:verification, ->(*) { flunk 'Copied code is not usable' }) do
        Handoff::Delivery.new(@record, @record.verification_revision).perform
      end
    end
    assert_equal 'cancelled', @record.reload.delivery_state
    assert_nil @record.encrypted_verification
  end

  def test_real_routes_require_same_origin_and_current_administrator
    body = { account_id: @account.id, handoff: { request_id: @request_id, recipient: @helper.email, provider: 'line' } }
    json_post('/toybaco/connections/handoffs', body, user: @owner, origin: 'https://foreign.example.test')
    assert_response :forbidden
    assert_equal 0, Toybaco::ConnectionHandoff.count
    json_post('/toybaco/connections/handoffs', body, user: @helper)
    assert_response :forbidden
    json_post('/toybaco/connections/handoffs', body, user: @owner)
    assert_response :created
    assert_equal 'issued', response.parsed_body['state']
    assert_match(%r{\Ahttps://app.staging.toybaco.jp/toybaco/connections/help/}, response.parsed_body['url'])
    assert_equal 'no-store', response.headers['Cache-Control']
  end

  def test_public_routes_use_recipient_identity_and_cookie_without_any_store_membership
    record, token = issue
    base = "/toybaco/connections/help/#{record.public_id}"
    json_post(base + '/open', { link_secret: token })
    assert_response :ok
    assert_equal @account.name, response.parsed_body['store_name']
    refute response.parsed_body.key?('account_id')
    refute response.parsed_body.key?('recipient')
    json_post(base + '/login', { link_secret: token }, user: @owner)
    assert_response :forbidden
    json_post(base + '/login', { link_secret: token }, user: @helper)
    assert_response :ok
    assert_equal 'claimed', response.parsed_body['state']
    enabled { get base + '/session' }
    assert_response :ok
    json_post(base + '/open', { link_secret: token })
    assert_response :forbidden
    refute @account.account_users.exists?(user_id: @helper.id)
    assert_nil record.reload.encrypted_recipient
    reset!
    host! 'app.staging.toybaco.jp'
    https!
    enabled { get base + '/session' }
    assert_response :forbidden
  end
end
