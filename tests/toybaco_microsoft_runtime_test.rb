# frozen_string_literal: true

# Real routes, cookies, database models, message builder and mail rendering.
# Microsoft HTTP and the not-yet-approved release are substituted only here.
require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require 'ostruct'
require 'uri'

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoMicrosoftRuntimeTest < ActionDispatch::IntegrationTest
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true

  Microsoft = Toybaco::Connections::Microsoft
  Api = Toybaco::Connections::MicrosoftApi
  Send = Toybaco::Connections::MicrosoftSend

  class FakeMicrosoft < Api
    attr_accessor :email, :subject_id, :send_error, :create_error, :on_receive, :on_create, :sent_copy, :refresh_data
    attr_reader :send_calls, :exchanges, :create_calls, :refresh_calls

    def initialize
      @email = "microsoft-#{SecureRandom.hex(8)}@example.test"
      @subject_id = SecureRandom.uuid
      @send_calls, @exchanges, @create_calls, @refresh_calls = [], [], [], []
    end

    def authorization_url(**args)
      Toybaco::Connections::MicrosoftAuthorizationApi.new(client_id: 'fixture-client', client_secret: 'fixture-secret',
        redirect_uri: 'https://app.example.test/toybaco/connections/microsoft/callback').authorization_url(**args)
    end

    def exchange(**args)
      @exchanges << args
      { 'access_token' => 'fixture-access', 'refresh_token' => 'fixture-refresh', 'expires_in' => 3600 }
    end

    def refresh(**args)
      @refresh_calls << args
      refresh_data || { 'access_token' => 'fresh-access', 'refresh_token' => nil, 'expires_in' => 3600 }
    end

    def profile(**_args)
      { 'id' => subject_id, 'mail' => email }
    end

    def inbox(**_args)
      { 'id' => 'Folder=' }
    end

    def delta(**_args)
      { 'value' => [{ 'id' => 'Received=' }],
        '@odata.deltaLink' => 'https://graph.microsoft.com/v1.0/me/mailFolders/Folder%3D/messages/delta?$deltatoken=fixture' }
    end

    def message(**args)
      return sent_copy || { 'id' => args[:id], 'isDraft' => true } unless args[:id] == 'Received='

      on_receive&.call
      { 'id' => 'Received=', 'isDraft' => false, 'internetMessageId' => '<received@example.test>', 'conversationId' => 'Thread=',
        'from' => { 'emailAddress' => { 'address' => 'visitor@example.test' } },
        'toRecipients' => [{ 'emailAddress' => { 'address' => email } }], 'subject' => 'Fixture inquiry',
        'receivedDateTime' => Time.now.utc.iso8601, 'body' => { 'contentType' => 'Text', 'content' => 'Fixture incoming body.' } }
    end

    def attachments(**_args)
      { 'value' => [] }
    end

    def create_reply(**args)
      @create_calls << args
      on_create&.call
      raise create_error if create_error

      { 'id' => "Draft#{@create_calls.length}=", 'isDraft' => true, 'internetMessageId' => '<reply@provider.example.test>' }
    end

    def create_draft(**args)
      create_reply(**args)
    end

    def send_draft(**args)
      @send_calls << args
      raise send_error if send_error

      { accepted: true, request_id: 'fixture-receipt' }
    end
  end

  def setup
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @account = create(:account)
    @user = create(:user, :administrator, account: @account)
    @api = FakeMicrosoft.new
  end

  def teardown
    Current.reset
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  def with_microsoft
    Microsoft.stub(:allowed?, true) do
      Microsoft.stub(:api, @api) do
        Microsoft.stub(:authorization_api, @api) do
          Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @user)) { yield }
        end
      end
    end
  end

  def connect(account: @account, api: @api)
    Microsoft.connect!(account: account, tokens: api.exchange(code: 'fixture', verifier: 'fixture'), profile: api.profile, folder: api.inbox)
  end

  def authorize
    post "/api/v1/accounts/#{@account.id}/microsoft/authorization", params: { return_to: 'growth' }, headers: @user.create_new_auth_token, as: :json
    assert_response :success
    URI.decode_www_form(URI(response.parsed_body.fetch('url')).query).to_h.fetch('state')
  end

  def reply(inbox)
    conversation = create(:conversation, account: @account, inbox: inbox)
    create(:message, account: @account, inbox: inbox, conversation: conversation, message_type: :incoming, content: 'Fixture request',
      source_id: 'received@example.test', content_attributes: { 'toybaco_microsoft_received' => { 'provider_id' => 'Received=' } })
    create(:message, account: @account, inbox: inbox, conversation: conversation, message_type: :outgoing, sender: @user,
      content: 'お問い合わせありがとうございます。')
  end

  def test_web_authorization_returns_to_original_store_once
    elsewhere = create(:account)
    with_microsoft do
      state = authorize
      @api.exchanges.clear
      get '/toybaco/connections/microsoft/callback', params: { state: state, code: 'fixture', account_id: elsewhere.id }
      assert_response :redirect
      assert_includes response.location, "/app/accounts/#{@account.id}/toybaco/start?toybaco_connection=connected"
      assert_equal 1, @account.inboxes.count
      assert_equal 0, elsewhere.inboxes.count
      get '/toybaco/connections/microsoft/callback', params: { state: state, code: 'fixture' }
      assert_response :bad_request
      assert_equal 1, @api.exchanges.length
    end
  end

  def test_admin_membership_is_rechecked_on_return
    with_microsoft do
      state = authorize
      @user.account_users.find_by!(account: @account).update!(role: :agent)
      get '/toybaco/connections/microsoft/callback', params: { state: state, code: 'fixture' }
      assert_response :forbidden
      assert_empty @api.exchanges
    end
  end

  def test_api_token_without_browser_cookie_cannot_start_connection
    Microsoft.stub(:allowed?, true) do
      post "/api/v1/accounts/#{@account.id}/microsoft/authorization", params: { return_to: 'growth' }, headers: @user.create_new_auth_token, as: :json
      assert_response :unauthorized
    end
  end

  def test_closed_release_does_not_fall_back_to_old_mail_configuration
    Microsoft.stub(:allowed?, false) do
      post "/api/v1/accounts/#{@account.id}/microsoft/authorization", params: { return_to: 'growth' }, headers: @user.create_new_auth_token, as: :json
      assert_response :service_unavailable
      assert_nil response.parsed_body['url']
    end
  end

  def test_cancelled_authorization_does_not_create_a_mailbox
    with_microsoft do
      state = authorize
      get '/toybaco/connections/microsoft/callback', params: { state: state, error: 'access_denied' }
      assert_response :redirect
      assert_includes response.location, 'toybaco_connection=cancelled'
      assert_empty @api.exchanges
      assert_equal 0, @account.inboxes.count
    end
  end

  def test_credentials_are_encrypted_bound_to_channel_and_disable_imap_smtp
    channel = connect.channel.reload
    assert_equal 'microsoft', channel.provider
    refute channel.imap_enabled
    refute channel.smtp_enabled
    refute_includes channel.provider_config.to_json, 'fixture-access'
    refute_includes channel.provider_config.to_json, 'fixture-refresh'
    assert_equal 'fixture-refresh', Microsoft.credentials(channel)['refresh_token']
    other = connect(account: create(:account), api: FakeMicrosoft.new).channel
    other.provider_config = channel.provider_config
    assert_raises(Api::Error, ActiveSupport::MessageEncryptor::InvalidMessage) { Microsoft.credentials(other) }
  end

  def test_alias_change_reuses_same_mailbox_and_preserves_history_cursor
    inbox = connect
    channel = inbox.channel
    old_revision = Microsoft.config(channel).fetch('connection_revision')
    Microsoft.update_config!(channel, Microsoft.config(channel).merge('sync' => { 'folder_id' => 'Folder=', 'cursor' => 'existing' }))
    @api.email = "alias-#{SecureRandom.hex(8)}@example.test"
    assert_equal inbox.id, connect.id
    assert_equal @api.email, channel.reload.email
    assert_equal 'existing', Microsoft.config(channel).dig('sync', 'cursor')
    refute_equal old_revision, Microsoft.config(channel)['connection_revision']
    assert_equal 1, @account.inboxes.count
  end

  def test_same_external_identity_cannot_be_assigned_to_another_store
    inbox = connect
    elsewhere = create(:account)
    @api.email = "different-alias-#{SecureRandom.hex(8)}@example.test"
    assert_raises(Api::Error) { connect(account: elsewhere) }
    assert_equal @account.id, inbox.channel.reload.account_id
    assert_equal 0, elsewhere.inboxes.count
  end

  def test_recycled_email_does_not_replace_existing_external_identity
    inbox = connect
    original = Microsoft.config(inbox.channel)['subject_id']
    @api.subject_id = SecureRandom.uuid
    assert_raises(Api::Error) { connect }
    assert_equal original, Microsoft.config(inbox.channel.reload)['subject_id']
  end

  def test_changing_client_application_requires_new_authorization
    channel = connect.channel
    Microsoft.stub(:client_id, 'a-different-application') do
      assert_raises(Api::Error) { Microsoft.access_token(channel) }
      refute Microsoft.application_current?(channel)
    end
  end

  def test_refresh_keeps_old_refresh_token_when_provider_does_not_rotate_it
    channel = connect.channel
    tokens = Microsoft.credentials(channel).merge('expires_at' => 0)
    Microsoft.update_config!(channel, Microsoft.config(channel).merge('credentials' => Microsoft.encode_credentials(channel, tokens)))
    with_microsoft do
      assert_equal 'fresh-access', Microsoft.access_token(channel)
      assert_equal 'fixture-refresh', Microsoft.credentials(channel)['refresh_token']
      assert_equal 1, @api.refresh_calls.length
    end
  end

  def test_real_reply_mail_is_sent_from_one_recorded_microsoft_draft
    message = reply(connect)
    with_microsoft do
      Email::SendOnEmailService.new(message: message).perform
      Email::SendOnEmailService.new(message: message.reload).perform
    end
    assert_equal 1, @api.create_calls.length
    assert_equal 1, @api.send_calls.length
    assert_equal 'Received=', @api.create_calls.first[:message_id]
    assert_includes @api.create_calls.first.dig(:message, 'body', 'content'), 'お問い合わせありがとうございます。'
    assert_equal [{ 'emailAddress' => { 'address' => @api.email } }], @api.create_calls.first.dig(:message, 'replyTo')
    assert_equal 'accepted', message.reload.content_attributes.dig(Send::KEY, 'state')
    assert_equal 'reply@provider.example.test', message.source_id
  end

  def test_uncertain_send_resolves_same_immutable_draft_without_sending_twice
    message = reply(connect)
    @api.send_error = Net::ReadTimeout.new
    with_microsoft do
      Send.new(message).perform
      assert_equal 'uncertain', message.reload.content_attributes.dig(Send::KEY, 'state')
      Send.new(message).perform
      assert_equal 1, @api.send_calls.length
      @api.sent_copy = { 'id' => 'Draft1=', 'isDraft' => false, 'sentDateTime' => Time.now.utc.iso8601,
                        'internetMessageId' => '<actual-sent@provider.example.test>' }
      Send.new(message).resolve
      assert_equal 'accepted', message.reload.content_attributes.dig(Send::KEY, 'state')
      assert_equal 'actual-sent@provider.example.test', message.source_id
      assert_equal 1, @api.create_calls.length
      assert_equal 1, @api.send_calls.length
    end
  end

  def test_known_rejection_needs_explicit_retry_before_creating_another_draft
    message = reply(connect)
    @api.send_error = Api::Error.new(429, '60')
    with_microsoft do
      Send.new(message).perform
      assert_equal 'rejected', message.reload.content_attributes.dig(Send::KEY, 'state')
      Send.new(message).perform
      assert_equal 1, @api.send_calls.length
      @api.send_error = nil
      message.update!(status: :sent)
      Send.new(message).perform
      assert_equal 2, @api.send_calls.length
      assert_equal 'accepted', message.reload.content_attributes.dig(Send::KEY, 'state')
    end
  end

  def test_uncertain_send_can_be_reconciled_after_same_mailbox_reauthorization
    message = reply(connect)
    @api.send_error = Net::ReadTimeout.new
    with_microsoft do
      Send.new(message).perform
      connect
      @api.sent_copy = { 'id' => 'Draft1=', 'isDraft' => false, 'sentDateTime' => Time.now.utc.iso8601,
                        'internetMessageId' => '<sent-after-reauth@provider.example.test>' }
      Send.new(message.reload).resolve
      assert_equal 'accepted', message.reload.content_attributes.dig(Send::KEY, 'state')
      assert_equal 'sent-after-reauth@provider.example.test', message.source_id
      assert_equal 1, @api.send_calls.length
    end
  end

  def test_reauthorization_during_preparation_prevents_old_worker_from_sending
    message = reply(connect)
    @api.on_create = -> { connect }
    with_microsoft { Send.new(message).perform }
    assert_empty @api.send_calls
    assert_equal 'rejected', message.reload.content_attributes.dig(Send::KEY, 'state')
  end

  def test_changed_message_during_preparation_is_never_sent_with_old_content
    message = reply(connect)
    @api.on_create = -> { Message.find(message.id).update!(content: '変更した本文') }
    with_microsoft { Send.new(message).perform }
    assert_empty @api.send_calls
    assert_equal '変更した本文', message.reload.content
    assert_equal 'rejected', message.content_attributes.dig(Send::KEY, 'state')
  end

  def test_removed_sender_during_preparation_cannot_send
    message = reply(connect)
    @api.on_create = -> { @user.account_users.find_by!(account: @account).destroy! }
    with_microsoft { Send.new(message).perform }
    assert_empty @api.send_calls
    assert_equal 'rejected', message.reload.content_attributes.dig(Send::KEY, 'state')
  end

  def test_fetch_creates_one_real_conversation_and_commits_delta_after_ingestion
    inbox = connect
    with_microsoft do
      Toybaco::MicrosoftFetchJob.perform_now(inbox.channel_id)
      Toybaco::MicrosoftFetchJob.perform_now(inbox.channel_id)
    end
    assert_equal 1, inbox.messages.where(message_type: :incoming).count
    message = inbox.messages.find_by!(source_id: 'received@example.test')
    assert_includes message.content, 'Fixture incoming body.'
    assert_equal 'Received=', message.content_attributes.dig('toybaco_microsoft_received', 'provider_id')
    assert_includes Microsoft.config(inbox.channel.reload).dig('sync', 'cursor'), '$deltatoken=fixture'
  end

  def test_reauthorization_during_fetch_cannot_import_from_old_connection
    inbox = connect
    @api.on_receive = -> { connect }
    with_microsoft { Toybaco::MicrosoftFetchJob.perform_now(inbox.channel_id) }
    assert_equal 0, inbox.messages.count
    assert_nil Microsoft.config(inbox.channel.reload).dig('sync', 'cursor')
  end

  def test_browser_cannot_inject_receipts_and_retry_cannot_erase_uncertainty
    inbox = connect
    message = reply(inbox)
    attrs = { Send::KEY => { 'state' => 'accepted' }, 'toybaco_microsoft_received' => { 'provider_id' => 'forged' } }
    built = Messages::MessageBuilder.new(@user, message.conversation, { content: 'new reply', message_type: 'outgoing',
      content_attributes: attrs, source_id: 'forged' }).perform
    refute built.content_attributes.key?(Send::KEY)
    refute built.content_attributes.key?('toybaco_microsoft_received')
    assert_nil built.source_id
    message.update!(status: :failed, content_attributes: { Send::KEY => { 'state' => 'uncertain', 'attempt_id' => 'fixture' } })
    post "/api/v1/accounts/#{@account.id}/conversations/#{message.conversation.display_id}/messages/#{message.id}/retry", headers: @user.create_new_auth_token, as: :json
    assert_response :success
    assert_equal 'uncertain', message.reload.content_attributes.dig(Send::KEY, 'state')
  end

  def test_deleting_connection_removes_credentials_and_stops_future_fetch
    inbox = connect
    channel = inbox.channel
    channel.destroy!
    with_microsoft { Toybaco::MicrosoftFetchJob.perform_now(channel.id) }
    assert_nil Channel::Email.find_by(id: channel.id)
    assert_empty @api.send_calls
  end

  def test_onboarding_completes_only_with_the_microsoft_receipt_for_its_mailbox
    terms = Toybaco::PlanCatalog.default.definition('free', '2026-09-18.1')
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: nil))
    message = reply(connect)
    guide = Toybaco::Growth::Onboarding.new(@account, @user)
    Toybaco::Growth::StoreFacts.new(@account).save!({ 'name' => 'テスト店舗' }, user: @user)
    with_microsoft do
      guide.update!('purpose' => 'inbox')
      assert_equal 'reply', guide.read['phase']
      assert_equal true, guide.read['microsoft_available']
      message.update!(source_id: 'not-microsoft', content_attributes: { 'toybaco_gmail_send' => {
        'state' => 'accepted', 'provider_id' => 'wrong-provider', 'accepted_at' => Time.now.utc.iso8601
      } })
      assert_equal 'reply', guide.read['phase']
      message.update!(source_id: nil, content_attributes: {})
      Send.new(message).perform
      assert_equal 'complete', guide.read['phase']
      assert_equal message.inbox_id, guide.read['inbox_id']
    end
  end

  def test_trial_identity_uses_stable_microsoft_subject_and_ignores_other_channels
    inbox = connect
    bot = create(:agent_bot, account: @account)
    create(:agent_bot_inbox, inbox: inbox, agent_bot: bot, status: :active)
    with_microsoft do
      first = Toybaco::Growth::TrialConnection.identity(inbox)
      assert_equal 'microsoft', first[:provider]
      @api.email = "trial-alias-#{SecureRandom.hex(6)}@example.test"
      connect
      assert_equal first, Toybaco::Growth::TrialConnection.identity(inbox.reload)
      widget = create(:inbox, account: @account, channel: create(:channel_widget, account: @account))
      assert_nil Toybaco::Growth::TrialConnection.identity(widget)
    end
  end
end
