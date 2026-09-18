# frozen_string_literal: true

# Run inside the fixed Chatwoot test image after db:schema:load/db:migrate.
# These tests use real Rails routes, encrypted cookies, DB models and mail views.
# Only the external Google HTTP boundary and the explicitly pending approval are
# substituted. They are not evidence of provider approval or external delivery.
require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require 'ostruct'
require 'uri'

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoGmailRuntimeTest < ActionDispatch::IntegrationTest
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true

  Gmail = Toybaco::Connections::Gmail
  Api = Toybaco::Connections::GmailApi

  class FakeGoogle
    attr_accessor :email, :send_error, :sent_results, :on_receive, :message_data, :attachment_result
    attr_reader :send_calls, :exchanges, :attachment_calls

    def initialize(email)
      @email = email
      @send_calls, @exchanges, @sent_results = [], [], []
      @attachment_calls = []
    end

    def authorization_url(**args)
      Api.new(client_id: 'fixture-client', client_secret: 'fixture-secret',
              redirect_uri: 'https://app.example.test/toybaco/connections/gmail/callback').authorization_url(**args)
    end

    def exchange(**args)
      @exchanges << args
      { 'access_token' => 'fixture-access-token', 'refresh_token' => 'fixture-refresh-token', 'expires_in' => 3600 }
    end

    def profile(**_args)
      { 'emailAddress' => email, 'historyId' => '100' }
    end

    def send_message(**args)
      @send_calls << args
      raise send_error if send_error

      { 'id' => 'provider-message-1' }
    end

    def history(**_args)
      { 'historyId' => '101', 'history' => [{ 'messagesAdded' => [{ 'message' => { 'id' => 'received-1' } }] }] }
    end

    def message(**_args)
      on_receive&.call
      return message_data if message_data

      text = 'Hello from a customer.'
      { 'id' => 'received-1', 'labelIds' => ['INBOX'], 'payload' => {
        'mimeType' => 'text/plain', 'headers' => [
          { 'name' => 'From', 'value' => 'visitor@example.test' }, { 'name' => 'To', 'value' => email },
          { 'name' => 'Subject', 'value' => 'Test inquiry' }, { 'name' => 'Message-ID', 'value' => '<received-1@example.test>' }
        ], 'body' => { 'size' => text.bytesize, 'data' => Base64.urlsafe_encode64(text) }
      } }
    end

    def attachment(**args)
      @attachment_calls << args
      raise attachment_result if attachment_result.is_a?(Exception)

      attachment_result
    end

    def sent_message(**_args)
      { 'messages' => sent_results }
    end
  end

  def setup
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @account = create(:account)
    @user = create(:user, :administrator, account: @account)
    @google = FakeGoogle.new("gmail-#{SecureRandom.hex(8)}@example.test")
  end

  def teardown
    Current.reset
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  def with_google
    Gmail.stub(:allowed?, true) do
      Gmail.stub(:api, @google) do
        Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @user)) { yield }
      end
    end
  end

  def connect
    Gmail.connect!(account: @account, tokens: @google.exchange(code: 'fixture', verifier: 'fixture'), profile: @google.profile)
  end

  def authorize(return_to: 'onboarding')
    post "/api/v1/accounts/#{@account.id}/google/authorization", params: { return_to: return_to },
         headers: @user.create_new_auth_token, as: :json
    assert_response :success
    URI.decode_www_form(URI(response.parsed_body.fetch('url')).query).to_h.fetch('state')
  end

  def reply(inbox)
    conversation = create(:conversation, account: @account, inbox: inbox)
    create(:message, account: @account, inbox: inbox, conversation: conversation, message_type: :outgoing,
                     sender: @user, content: 'お問い合わせありがとうございます。')
  end

  def test_real_authorization_cookie_and_callback_connect_once_to_the_original_store
    elsewhere = create(:account)
    with_google do
      state = authorize
      get '/toybaco/connections/gmail/callback', params: { state: state, code: 'fixture-code', account_id: elsewhere.id }
      assert_response :redirect
      assert_includes response.location, "/app/accounts/#{@account.id}/onboarding/inbox-setup?toybaco_connection=connected"
      assert_equal 1, @account.inboxes.count
      assert_equal 0, elsewhere.inboxes.count
      assert_equal 1, @google.exchanges.size
      get '/toybaco/connections/gmail/callback', params: { state: state, code: 'fixture-code' }
      assert_response :bad_request
      assert_equal 1, @google.exchanges.size
    end
  end

  def test_removed_admin_permission_is_rechecked_after_google_returns
    with_google do
      state = authorize
      @user.account_users.find_by!(account: @account).update!(role: :agent)
      get '/toybaco/connections/gmail/callback', params: { state: state, code: 'fixture-code' }
      assert_response :forbidden
      assert_empty @google.exchanges
      assert_equal 0, @account.inboxes.count
    end
  end

  def test_growth_authorization_returns_to_the_same_store_tour
    with_google do
      state = authorize(return_to: 'growth')
      get '/toybaco/connections/gmail/callback', params: { state: state, code: 'fixture-code' }
      assert_response :redirect
      assert_includes response.location, "/app/accounts/#{@account.id}/toybaco/start?toybaco_connection=connected"
      assert_equal 1, @account.inboxes.count
    end
  end

  def test_growth_authorization_never_falls_back_to_legacy_mail_setup
    Gmail.stub(:allowed?, false) do
      post "/api/v1/accounts/#{@account.id}/google/authorization", params: { return_to: 'growth' },
           headers: @user.create_new_auth_token, as: :json
      assert_response :service_unavailable
      assert_nil response.parsed_body['url']
      assert_equal 0, @account.inboxes.count
    end
  end

  def test_a_cancelled_google_prompt_does_not_create_or_charge_anything
    with_google do
      state = authorize
      get '/toybaco/connections/gmail/callback', params: { state: state, error: 'access_denied' }
      assert_response :redirect
      assert_includes response.location, 'toybaco_connection=cancelled'
      assert_empty @google.exchanges
      assert_equal 0, @account.inboxes.count
    end
  end

  def test_rest_credentials_are_encrypted_and_old_imap_smtp_are_disabled
    inbox = connect
    channel = inbox.channel.reload
    assert_equal 'google', channel.provider
    refute channel.imap_enabled
    refute channel.smtp_enabled
    refute_includes channel.provider_config.to_json, 'fixture-access-token'
    refute_includes channel.provider_config.to_json, 'fixture-refresh-token'
    assert_equal 'fixture-refresh-token', Gmail.credentials(channel).fetch('refresh_token')
  end

  def test_encrypted_credentials_cannot_be_copied_to_another_store
    inbox = connect
    other_account = create(:account)
    other_google = FakeGoogle.new("other-#{SecureRandom.hex(8)}@example.test")
    other_inbox = Gmail.connect!(account: other_account, tokens: other_google.exchange, profile: other_google.profile)
    other_inbox.channel.update!(provider_config: inbox.channel.provider_config)
    assert_raises(Api::Error, ActiveSupport::MessageEncryptor::InvalidMessage) { Gmail.credentials(other_inbox.channel.reload) }
  end

  def test_reconnection_keeps_the_inbox_and_history_and_fences_old_workers
    inbox = connect
    channel = inbox.channel
    original_revision = Gmail.config(channel).fetch('connection_revision')
    Gmail.update_config!(channel, Gmail.config(channel).merge('sync' => { 'history_id' => '777' }))
    connected_again = connect
    assert_equal inbox.id, connected_again.id
    assert_equal 1, @account.inboxes.count
    assert_equal '777', Gmail.config(channel.reload).dig('sync', 'history_id')
    refute_equal original_revision, Gmail.config(channel).fetch('connection_revision')
  end

  def test_a_mailbox_owned_by_another_store_is_never_transferred
    inbox = connect
    other = create(:account)
    assert_raises(ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique) do
      Gmail.connect!(account: other, tokens: @google.exchange, profile: @google.profile)
    end
    assert_equal @account.id, inbox.channel.reload.account_id
    assert_equal 0, other.inboxes.count
  end

  def test_the_existing_reply_service_renders_real_mail_and_uses_gmail_once
    message = reply(connect)
    with_google do
      Email::SendOnEmailService.new(message: message).perform
      Email::SendOnEmailService.new(message: message.reload).perform
    end
    assert_equal 1, @google.send_calls.size
    raw = Mail.read_from_string(@google.send_calls.first.fetch(:raw))
    assert_includes raw.from, @google.email
    assert_includes raw.reply_to, @google.email
    assert_equal message.reload.source_id, raw.message_id
    assert_equal 'accepted', message.content_attributes.dig('toybaco_gmail_send', 'state')
    assert_equal 'sent', message.status
  end

  def test_ambiguous_send_is_reconciled_without_resending
    message = reply(connect)
    @google.send_error = IOError.new('fixture timeout')
    with_google do
      Email::SendOnEmailService.new(message: message).perform
      assert_equal 'uncertain', message.reload.content_attributes.dig('toybaco_gmail_send', 'state')
      Email::SendOnEmailService.new(message: message).perform
      assert_equal 1, @google.send_calls.size
      @google.sent_results = [{ 'id' => 'already-sent-provider-id' }]
      Toybaco::Connections::GmailSend.new(message).resolve
      assert_equal 'accepted', message.reload.content_attributes.dig('toybaco_gmail_send', 'state')
      assert_equal 'sent', message.status
      assert_equal 1, @google.send_calls.size
    end
  end
  def test_a_provider_timeout_status_never_allows_a_second_send
    message = reply(connect)
    @google.send_error = Api::Error.new(408)
    with_google do
      2.times { Email::SendOnEmailService.new(message: message.reload).perform }
      assert_equal 1, @google.send_calls.size
      assert_equal 'uncertain', message.reload.content_attributes.dig('toybaco_gmail_send', 'state')
    end
  end

  def test_a_late_failure_cannot_overwrite_a_reconciled_success
    message = reply(connect)
    @google.send_error = IOError.new('fixture timeout')
    with_google do
      service = Toybaco::Connections::GmailSend.new(message)
      service.perform
      attempt = message.reload.content_attributes.fetch('toybaco_gmail_send').dup
      @google.sent_results = [{ 'id' => 'already-sent-provider-id' }]
      service.resolve
      service.send(:uncertain, attempt)
      assert_equal 'sent', message.reload.status
      assert_equal 'accepted', message.content_attributes.dig('toybaco_gmail_send', 'state')
      assert_equal 1, @google.send_calls.size
    end
  end

  def test_fetch_creates_one_real_incoming_message_and_never_duplicates_it
    inbox = connect
    with_google { 2.times { Toybaco::GmailFetchJob.perform_now(inbox.channel_id) } }
    messages = inbox.messages.where(source_id: 'received-1@example.test')
    assert_equal 1, messages.count
    assert_equal 'incoming', messages.first.message_type
    assert_includes messages.first.content, 'Hello from a customer.'
    assert_equal '101', Gmail.config(inbox.channel.reload).dig('sync', 'history_id')
  end

  def test_browser_cannot_supply_a_gmail_receipt_or_provider_message_id
    inbox = connect
    conversation = create(:conversation, account: @account, inbox: inbox)
    post "/api/v1/accounts/#{@account.id}/conversations/#{conversation.display_id}/messages",
         params: { content: 'テストの返信', message_type: 'outgoing', source_id: 'forged@example.test',
                   content_attributes: { toybaco_gmail_send: { state: 'accepted', provider_id: 'forged' } } },
         headers: @user.create_new_auth_token, as: :json
    assert_response :success
    created = conversation.messages.outgoing.last
    assert_nil created.content_attributes['toybaco_gmail_send']
    assert_nil created.source_id
  end

  def test_browser_retry_preserves_an_uncertain_send_and_never_posts_it_again
    message = reply(connect)
    @google.send_error = IOError.new('fixture timeout')
    with_google do
      Email::SendOnEmailService.new(message: message).perform
      before = message.reload.content_attributes.fetch('toybaco_gmail_send').dup
      post "/api/v1/accounts/#{@account.id}/conversations/#{message.conversation.display_id}/messages/#{message.id}/retry",
           headers: @user.create_new_auth_token, as: :json
      assert_response :success
      assert_equal before, message.reload.content_attributes.fetch('toybaco_gmail_send')
      Email::SendOnEmailService.new(message: message).perform
      assert_equal 1, @google.send_calls.size
      assert_equal 'uncertain', message.reload.content_attributes.dig('toybaco_gmail_send', 'state')
    end
  end

  def test_reauthorization_during_fetch_fences_the_old_worker
    inbox = connect
    @google.on_receive = lambda do
      channel = Channel::Email.find(inbox.channel_id)
      Gmail.update_config!(channel, Gmail.config(channel).merge('connection_revision' => 'new-authorization'))
    end
    with_google { Toybaco::GmailFetchJob.perform_now(inbox.channel_id) }
    assert_equal 0, inbox.messages.count
    assert_equal '100', Gmail.config(inbox.channel.reload).dig('sync', 'history_id')
  end

  def test_large_attachment_keeps_the_body_small_file_and_one_private_notice
    inbox = connect
    data = @google.message
    body = data['payload'].delete('body')
    data['payload']['mimeType'] = 'multipart/mixed'
    data['payload']['parts'] = [
      { 'mimeType' => 'text/plain', 'body' => body },
      { 'mimeType' => 'application/pdf', 'filename' => 'large.pdf', 'body' => { 'size' => 30_000_000, 'attachmentId' => 'large' } },
      { 'mimeType' => 'application/pdf', 'filename' => 'small.pdf', 'body' => { 'size' => 5, 'attachmentId' => 'small' } }
    ]
    @google.message_data = data
    @google.attachment_result = { 'size' => 5, 'data' => Base64.urlsafe_encode64('SMALL') }
    with_google { 2.times { Toybaco::GmailFetchJob.perform_now(inbox.channel_id) } }
    incoming = inbox.messages.where(message_type: :incoming).sole
    assert_includes incoming.content, 'Hello from a customer.'
    assert_equal 'SMALL', incoming.attachments.sole.file.download
    omissions = incoming.content_attributes.dig('toybaco_gmail_received', 'omitted_attachments')
    assert_equal ['large.pdf'], omissions.map { |item| item['name'] }
    assert_equal ['small'], @google.attachment_calls.map { |call| call[:id] }
    notice = inbox.messages.where(message_type: :activity).sole
    assert notice.private?
    assert_includes notice.content, '25MB超過'
    assert_empty @google.send_calls
    assert_equal '101', Gmail.config(inbox.channel.reload).dig('sync', 'history_id')
  end

end
