# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require 'ostruct'
require Rails.root.join('lib/toybaco/connections/handoff/issue')
require Rails.root.join('lib/toybaco/connections/handoff/verification')
require Rails.root.join('lib/toybaco/connections/handoff/mail_setup')
require Rails.root.join('lib/toybaco/connections/handoff/mail_oauth_state')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoHandoffMailRuntimeTest < ActionDispatch::IntegrationTest
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true
  Handoff = Toybaco::Connections::Handoff
  NOW = Time.utc(2026, 9, 19, 8)

  class Gateway < Handoff::MailGateway
    attr_accessor :available, :application_binding, :email, :subject_id, :on_exchange
    attr_reader :provider, :exchanges, :enqueued

    def initialize(provider)
      super
      @provider = provider
      @available = true
      @application_binding = 'b' * 64
      @email = "mail-helper-#{SecureRandom.uuid}@example.test"
      @subject_id = SecureRandom.uuid
      @exchanges = []
      @enqueued = []
    end

    def allowed?(_account)
      available
    end

    def binding
      application_binding
    end

    def authorization_url(**options)
      klass = provider == 'gmail' ? Toybaco::Connections::GmailApi : Toybaco::Connections::MicrosoftAuthorizationApi
      klass.new(client_id: 'fixture-client', client_secret: 'fixture-secret', redirect_uri: callback_url).authorization_url(**options)
    end

    def data
      result = { tokens: { 'access_token' => 'fixture-access', 'refresh_token' => 'fixture-refresh', 'expires_in' => 3600 },
                 profile: provider == 'gmail' ? { 'emailAddress' => email, 'historyId' => '100' } : { 'mail' => email, 'id' => subject_id } }
      result[:folder] = { 'id' => 'Folder=' } if provider == 'microsoft'
      result
    end

    def exchange(**options)
      @exchanges << options
      on_exchange&.call
      data
    end

    def enqueue(inbox)
      @enqueued << inbox.id
    end
  end

  def setup
    travel_to NOW
    @adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @old_env = ENV.to_h.slice('FRONTEND_URL', 'TOYBACO_DEPLOYMENT_ENVIRONMENT')
    ENV['FRONTEND_URL'] = 'https://app.staging.toybaco.jp'
    ENV['TOYBACO_DEPLOYMENT_ENVIRONMENT'] = 'staging'
    @account = create(:account)
    @owner = create(:user, :administrator, account: @account)
    @helper = create(:user, email: "mail-recipient-#{SecureRandom.uuid}@example.test")
    terms = Toybaco::PlanCatalog.default.definition('free', '2026-09-25.1')
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: nil))
    @nonce = SecureRandom.hex(32)
    @gateway = Gateway.new('gmail')
    host! 'app.staging.toybaco.jp'
    https!
  end

  def teardown
    %w[FRONTEND_URL TOYBACO_DEPLOYMENT_ENVIRONMENT].each { |key| @old_env.key?(key) ? ENV[key] = @old_env[key] : ENV.delete(key) }
    ActiveJob::Base.queue_adapter = @adapter
    travel_back
    Current.reset
  end

  def enabled(&block)
    Handoff::Access.stub(:enabled?, true, &block)
  end

  def with_gateway(&block)
    enabled { Handoff::MailGateway.stub(:new, @gateway, &block) }
  end

  def issue(inbox_id: nil)
    enabled do
      @record, @token = Handoff::Issue.new(@account, @owner).create!(request_id: SecureRandom.uuid, recipient: @helper.email,
                                        provider: @gateway.provider, inbox_id: inbox_id)
    end
  end

  def claim(inbox_id: nil)
    issue(inbox_id: inbox_id)
    enabled { Handoff::Verification.new(@record).login!(token: @token, browser_nonce: @nonce, user: @helper) }
  end

  def save
    enabled { Handoff::MailSetup.new(@record, gateway: @gateway).save!(browser_nonce: @nonce, payload: @gateway.data) }
  end

  def endpoint(suffix)
    "/toybaco/connections/help/#{@record.public_id}/#{suffix}"
  end

  def json_post(path, body = {}, origin: ENV.fetch('FRONTEND_URL'))
    with_gateway do
      Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @helper)) do
        post path, params: body, as: :json, headers: { 'Origin' => origin, 'Sec-Fetch-Site' => 'same-origin' }
      end
    end
  end

  def authorize
    issue
    json_post(endpoint('open'), { link_secret: @token })
    assert_response :success
    json_post(endpoint('login'), { link_secret: @token })
    assert_response :success
    json_post(endpoint('mail'))
    assert_response :success
    uri = URI(response.parsed_body.fetch('url'))
    query = URI.decode_www_form(uri.query).to_h
    assert_equal 'S256', query.fetch('code_challenge_method')
    assert_equal ENV.fetch('FRONTEND_URL') + "/toybaco/connections/help/oauth/#{@gateway.provider}/callback", query.fetch('redirect_uri')
    @state = query.fetch('state')
    @challenge = query.fetch('code_challenge')
  end

  def callback(provider: @gateway.provider, error: nil)
    with_gateway do
      get "/toybaco/connections/help/oauth/#{provider}/callback", params: { state: @state, code: 'fixture-code', error: error }.compact
    end
  end

  def test_gmail_authorization_actual_encrypted_save_and_scoped_receipt
    authorize
    callback
    assert_redirected_to "/toybaco/connections/help/#{@record.public_id}?mail=connected"
    inbox = @account.inboxes.sole
    assert_equal 'completed', @record.reload.state
    assert_equal inbox.id, @record.result_inbox_id
    assert_equal [inbox.id], @gateway.enqueued
    assert_equal 1, @gateway.exchanges.size
    assert_equal @challenge, Base64.urlsafe_encode64(Digest::SHA256.digest(@gateway.exchanges.sole.fetch(:verifier)), padding: false)
    assert_equal 'fixture-refresh', Toybaco::Connections::Gmail.credentials(inbox.channel).fetch('refresh_token')
    refute_includes inbox.channel.provider_config.to_json, 'fixture-refresh'
    refute AccountUser.exists?(account: @account, user: @helper)
    with_gateway { get endpoint('mail') }
    assert_response :success
    %w[fixture-access fixture-refresh @example.test account_id conversation].each { |secret| refute_includes response.body, secret }
    callback
    assert_response :forbidden
    assert_equal 1, @gateway.exchanges.size
  end

  def test_microsoft_authorization_saves_native_identity_without_store_membership
    @gateway = Gateway.new('microsoft')
    authorize
    callback
    assert_response :redirect
    inbox = @account.inboxes.sole
    assert_equal 'microsoft', inbox.channel.provider
    assert_equal @gateway.subject_id, Toybaco::Connections::Microsoft.config(inbox.channel).fetch('subject_id')
    assert_equal 'fixture-access', Toybaco::Connections::Microsoft.credentials(inbox.channel).fetch('access_token')
    refute_includes inbox.channel.provider_config.to_json, 'fixture-access'
    refute AccountUser.exists?(account: @account, user: @helper)
  end

  def test_callback_requires_the_claimed_browser
    authorize
    reset!
    host! 'app.staging.toybaco.jp'
    https!
    callback
    assert_response :forbidden
    assert_empty @gateway.exchanges
    assert_empty @account.inboxes
  end

  def test_provider_mixup_cannot_exchange_code
    authorize
    callback(provider: 'microsoft')
    assert_response :forbidden
    assert_empty @gateway.exchanges
  end

  def test_cancelled_authorization_is_consumed
    authorize
    callback(error: 'access_denied')
    assert_redirected_to "/toybaco/connections/help/#{@record.public_id}?mail=cancelled"
    callback
    assert_response :forbidden
    assert_empty @gateway.exchanges
  end

  def test_revocation_expiry_and_creator_role_loss_prevent_exchange
    %i[revoke expire role].each do |change|
      authorize
      case change
      when :revoke then @record.update!(state: 'revoked')
      when :expire then @record.update!(expires_at: NOW - 1)
      when :role then @account.account_users.find_by!(user: @owner).update!(role: 'agent')
      end
      callback
      assert_response :forbidden
      assert_empty @gateway.exchanges
      @account.account_users.find_by!(user: @owner).update!(role: 'administrator')
    end
  end

  def test_application_change_invalidates_old_authorization
    authorize
    @gateway.application_binding = 'd' * 64
    callback
    assert_response :forbidden
    assert_empty @gateway.exchanges
  end

  def test_permission_change_during_exchange_cannot_write_connection
    authorize
    @gateway.on_exchange = -> { @account.account_users.find_by!(user: @owner).update!(role: 'agent') }
    callback
    assert_response :forbidden
    assert_empty @account.inboxes
    assert_equal 'claimed', @record.reload.state
  end

  def test_application_change_during_exchange_cannot_write_connection
    authorize
    @gateway.on_exchange = -> { @gateway.application_binding = 'c' * 64 }
    callback
    assert_response :forbidden
    assert_empty @account.inboxes
  end

  def test_release_closure_is_rechecked_before_exchange_and_commit
    authorize
    @gateway.available = false
    callback
    assert_response :service_unavailable
    assert_empty @gateway.exchanges
    @gateway.available = true
    authorize
    @gateway.on_exchange = -> { @gateway.available = false }
    callback
    assert_response :service_unavailable
    assert_empty @account.inboxes
  end

  def test_new_connection_cannot_modify_existing_mailbox_without_explicit_target
    original = @gateway.connect!(account: @account, payload: @gateway.data)
    old_config = original.channel.provider_config.deep_dup
    claim
    assert_raises(Handoff::Forbidden) { save }
    assert_equal old_config, original.channel.reload.provider_config
    assert_equal 1, @account.inboxes.count
  end

  def test_explicit_existing_target_keeps_the_original_inbox
    original = @gateway.connect!(account: @account, payload: @gateway.data)
    claim(inbox_id: original.id)
    result = save
    assert_equal original.id, result.id
    assert_equal 1, @account.inboxes.count
    assert_equal 'completed', @record.reload.state
  end

  def test_existing_target_rejects_a_different_mailbox
    original = @gateway.connect!(account: @account, payload: @gateway.data)
    claim(inbox_id: original.id)
    @gateway.email = 'other-mailbox@example.test'
    assert_raises(Handoff::Forbidden) { save }
    assert_equal 1, @account.inboxes.count
    refute_equal @gateway.email, original.channel.reload.email
  end

  def test_microsoft_identity_from_another_store_is_rejected
    @gateway = Gateway.new('microsoft')
    other = create(:account)
    original = @gateway.connect!(account: other, payload: @gateway.data)
    claim
    assert_raises(Handoff::Forbidden) { save }
    assert_empty @account.inboxes
    assert_equal other.id, original.reload.account_id
  end

  def test_current_inbox_limit_is_enforced_at_commit
    claim
    2.times { create(:inbox, account: @account) }
    assert_raises(Toybaco::Connections::GmailApi::Error) { save }
    assert_equal 2, @account.inboxes.count
    assert_equal 'claimed', @record.reload.state
  end

  def test_forged_origin_cannot_start_provider_authorization
    issue
    json_post(endpoint('open'), { link_secret: @token })
    json_post(endpoint('login'), { link_secret: @token })
    json_post(endpoint('mail'), {}, origin: 'https://untrusted.example.test')
    assert_response :forbidden
    assert_empty @gateway.exchanges
  end

  def test_callback_registration_must_match_application_environment_and_implementation
    gateway = Handoff::MailGateway.new('gmail')
    Toybaco::Connections::Gmail.stub(:allowed?, true) do
      Toybaco::Connections::Gmail.stub(:client_id, 'fixture-client') do
        refute gateway.allowed?(@account)
        config = InstallationConfig.find_or_initialize_by(name: 'TOYBACO_CONNECTION_HANDOFF_MAIL')
        entry = { 'application_id' => 'fixture-client', 'callback_url' => gateway.send(:callback_url),
                  'implementation_revision' => Toybaco::Connections::GmailApi::REVISION }
        config.update!(value: { 'staging' => { 'gmail' => entry } })
        assert gateway.allowed?(@account)
        config.update!(value: { 'staging' => { 'gmail' => entry.merge('callback_url' => 'https://untrusted.example.test') } })
        refute gateway.allowed?(@account)
      end
    end
  end

  def test_queue_admission_failure_keeps_the_completed_connection
    claim
    inbox = save
    gateway = Handoff::MailGateway.new('gmail')
    Toybaco::GmailFetchJob.stub(:perform_later, ->(*) { raise IOError, 'queue unavailable fixture' }) do
      refute gateway.enqueue(inbox)
    end
    assert_equal 'completed', @record.reload.state
    assert_equal inbox.id, @record.result_inbox_id
  end

  def owner_page(**query)
    with_gateway do
      Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @owner)) do
        get '/toybaco/connections/handoff', params: { account_id: @account.id, provider: @gateway.provider }.merge(query)
      end
    end
  end

  def test_owner_page_carries_the_selected_mail_provider_without_line_fields
    owner_page
    assert_response :success
    assert_select '#handoff[data-provider="gmail"][data-create-available="true"]'
    assert_select '.eyebrow', text: "#{@account.name} · Google"
    refute_includes response.body, 'チャネルシークレット'
    assert_equal 'no-store', response.headers['Cache-Control']
  end

  def test_existing_target_is_validated_before_rendering_the_request_page
    original = @gateway.connect!(account: @account, payload: @gateway.data)
    owner_page(inbox_id: original.id)
    assert_response :success
    assert_select "#handoff[data-inbox-id='#{original.id}']"
    other = create(:account)
    foreign = create(:inbox, account: other)
    owner_page(inbox_id: foreign.id)
    assert_response :forbidden
  end

  def test_existing_request_can_still_be_viewed_when_new_authorization_is_closed
    issue
    @gateway.available = false
    owner_page(id: @record.public_id, provider: 'microsoft')
    assert_response :success
    assert_select '#handoff[data-provider="gmail"][data-create-available="false"]'
    owner_page
    assert_response :service_unavailable
  end

  def test_owner_page_rejects_unsupported_provider_and_malformed_target
    owner_page(provider: 'website')
    assert_response :unprocessable_entity
    owner_page(inbox_id: '1abc')
    assert_response :unprocessable_entity
  end

  def test_portal_does_not_disclose_store_or_provider_before_identity_verification
    issue
    enabled { get "/toybaco/connections/help/#{@record.public_id}" }
    assert_response :success
    assert_select '#mail-connect[hidden]'
    assert_select '#line-form[hidden]'
    refute_includes response.body, @account.name
    assert_select 'title', text: '接続設定 | トイバコ'
  end

  def test_onboarding_shows_mail_delegation_only_to_current_administrators_when_enabled
    require Rails.root.join('lib/toybaco/growth/onboarding')
    with_gateway do
      assert_equal %w[gmail microsoft], Toybaco::Growth::Onboarding.new(@account, @owner).read.fetch('handoff_mail_available')
      @account.account_users.find_by!(user: @owner).update!(role: 'agent')
      assert_empty Toybaco::Growth::Onboarding.new(@account, @owner).read.fetch('handoff_mail_available')
    end
    @account.account_users.find_by!(user: @owner).update!(role: 'administrator')
    Handoff::Access.stub(:enabled?, false) do
      assert_empty Toybaco::Growth::Onboarding.new(@account, @owner).read.fetch('handoff_mail_available')
    end
  end

end
