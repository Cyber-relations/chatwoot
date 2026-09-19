# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require 'ostruct'
require Rails.root.join('lib/toybaco/growth/onboarding')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoGrowthOnboardingRuntimeTest < ActionDispatch::IntegrationTest
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true
  Gmail = Toybaco::Connections::Gmail
  Facts = Toybaco::Growth::StoreFacts

  def setup
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @account = create(:account)
    @user = create(:user, :administrator, account: @account)
    terms = Toybaco::PlanCatalog.default.definition('free', '2026-09-18.1')
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: nil))
  end

  def teardown
    Current.reset
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  def authenticated
    Gmail.stub(:allowed?, true) do
      Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @user)) { yield }
    end
  end

  def connect(account = @account)
    Gmail.connect!(account: account,
                   tokens: { 'access_token' => 'fixture-access', 'refresh_token' => 'fixture-refresh', 'expires_in' => 3600 },
                   profile: { 'emailAddress' => "guide-#{SecureRandom.hex(10)}@example.test", 'historyId' => '100' })
  end

  def update_preference(preference, id: @account.id)
    put '/toybaco/growth/onboarding', params: { account_id: id, preference: preference },
         headers: { 'Origin' => 'http://www.example.com' }, as: :json
  end

  def read_guide
    get '/toybaco/growth/onboarding', params: { account_id: @account.id }
    assert_response :success
    response.parsed_body
  end

  def test_client_flags_cannot_complete_a_connection_or_tour
    authenticated do
      update_preference({ purpose: 'inbox', phase: 'complete', connected: true })
      assert_response :success
      assert_equal 'connect', response.parsed_body['phase']
      assert_empty response.parsed_body['inboxes']
    end
  end

  def test_progress_requires_real_incoming_and_provider_accepted_reply
    authenticated do
      update_preference({ purpose: 'inbox' })
      inbox = connect
      assert_equal 'facts', read_guide['phase']
      Facts.new(@account).save!({ 'name' => 'テスト店舗' }, user: @user)
      assert_equal 'receive', read_guide['phase']
      conversation = create(:conversation, account: @account, inbox: inbox)
      create(:message, account: @account, inbox: inbox, conversation: conversation,
                       message_type: :incoming, private: false, source_id: 'received-guide@example.test')
      message = create(:message, account: @account, inbox: inbox, conversation: conversation,
                                 message_type: :outgoing, private: false, sender: @user, status: :sent)
      assert_equal 'reply', read_guide['phase']
      message.update!(content_attributes: { 'toybaco_gmail_send' => { 'state' => 'accepted' } })
      assert_equal 'reply', read_guide['phase']
      message.update!(source_id: 'sent-guide@example.test', content_attributes: {
        'toybaco_gmail_send' => { 'state' => 'accepted', 'provider_id' => 'provider-guide', 'accepted_at' => Time.now.utc.iso8601 }
      })
      assert_equal 'accepted', message.reload.content_attributes.dig('toybaco_gmail_send', 'state')
      assert_equal 'complete', read_guide['phase']
      assert_equal conversation.display_id, response.parsed_body['conversation_id']
    end
  end

  def test_other_store_and_its_inbox_are_never_visible_or_selected
    elsewhere = create(:account)
    inbox = connect(elsewhere)
    authenticated do
      get '/toybaco/growth/onboarding', params: { account_id: elsewhere.id }
      assert_response :forbidden
      update_preference({ purpose: 'inbox', inbox_id: inbox.id })
      assert_response :unprocessable_entity
      assert_nil read_guide.dig('preference', 'inbox_id')
    end
  end

  def test_facts_require_same_origin_and_current_store_administrator
    input = { account_id: @account.id, confirmed: true, fields: { name: '店舗', hours: '平日10時から18時' } }
    authenticated do
      put '/toybaco/growth/facts', params: input, headers: { 'Origin' => 'https://elsewhere.test' }, as: :json
      assert_response :forbidden
      refute Facts.new(@account.reload).read['confirmed']
      put '/toybaco/growth/facts', params: input, headers: { 'Origin' => 'http://www.example.com' }, as: :json
      assert_response :success
      assert_equal '平日10時から18時', Facts.new(@account.reload).read.dig('fields', 'hours')
      @user.account_users.find_by!(account: @account).update!(role: :agent)
      put '/toybaco/growth/facts', params: input, headers: { 'Origin' => 'http://www.example.com' }, as: :json
      assert_response :forbidden
    end
  end

  def test_dismissal_is_personal_and_never_confirms_store_facts
    authenticated do
      update_preference({ purpose: 'inbox', dismissed: true })
      assert_response :success
      assert_equal true, response.parsed_body.dig('preference', 'dismissed')
      another = create(:user, :administrator, account: @account)
      progress = Toybaco::Growth::Onboarding.new(@account, another).read
      assert_equal 'purpose', progress['phase']
      assert_nil progress.dig('preference', 'dismissed')
      refute Facts.new(@account).read['confirmed']
    end
  end

  def test_removed_membership_cannot_read_saved_facts
    Facts.new(@account).save!({ 'name' => '非公開の店舗名' }, user: @user)
    @user.account_users.find_by!(account: @account).destroy!
    authenticated do
      get '/toybaco/growth/onboarding', params: { account_id: @account.id }
      assert_response :forbidden
      refute_includes response.body, '非公開の店舗名'
    end
  end

  class LineClient
    attr_accessor :response
    attr_reader :pushes

    def initialize
      @response = OpenStruct.new(code: '200', body: '{}')
      @pushes = []
    end

    def get_profile(_id)
      OpenStruct.new(body: JSON.generate('userId' => "U#{'a' * 32}", 'displayName' => '案内確認'))
    end

    def push_message(recipient, payload)
      @pushes << [recipient, payload]
      response
    end
  end

  def line_inbox(account = @account)
    channel = Channel::Line.create!(account: account, line_channel_id: SecureRandom.random_number(10**10).to_s,
                                   line_channel_secret: 'a' * 32, line_channel_token: 'lineFixtureToken')
    account.inboxes.create!(channel: channel, name: 'テスト店舗 LINE')
  end

  def with_line_client(client)
    factory = lambda do |&configure|
      configure.call(OpenStruct.new)
      client
    end
    Line::Bot::Client.stub(:new, factory) { yield }
  end

  def receive_line(inbox, client: LineClient.new, valid: true)
    payload = { 'events' => [{ 'type' => 'message', 'source' => { 'type' => 'user', 'userId' => "U#{'a' * 32}" },
                              'message' => { 'type' => 'text', 'id' => '1234567890', 'text' => '営業時間を教えてください' } }] }
    body = JSON.generate(payload)
    signature = Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', inbox.channel.line_channel_secret, body))
    with_line_client(client) do
      Webhooks::LineEventsJob.perform_now(params: { line_channel_id: inbox.channel.line_channel_id, line: payload }.with_indifferent_access,
                                         signature: valid ? signature : 'invalid', post_body: body)
    end
    inbox.messages.incoming.order(:id).last
  end

  def prepare_line(inbox)
    update_preference({ purpose: 'inbox', inbox_id: inbox.id })
    assert_response :success
    Facts.new(@account).save!({ 'name' => 'テスト店舗' }, user: @user)
  end

  def line_reply(incoming, sender: @user, private_note: false)
    create(:message, account: @account, inbox: incoming.inbox, conversation: incoming.conversation,
                     message_type: :outgoing, private: private_note, sender: sender, content: '本日は18時までです。', status: :sent)
  end

  def test_line_setup_continues_through_signed_receipt_and_native_api_acceptance
    authenticated do
      inbox = line_inbox
      update_preference({ purpose: 'inbox' })
      assert_equal 'facts', read_guide['phase']
      prepare_line(inbox)
      state = read_guide
      assert_equal 'receive', state['phase']
      assert_equal 'line', state['inboxes'].first['provider']
      assert_nil state['inboxes'].first['email']
      refute_includes response.body, inbox.channel.line_channel_secret
      refute_includes response.body, inbox.channel.line_channel_token
      client = LineClient.new
      incoming = receive_line(inbox, client: client)
      assert_equal 'reply', read_guide['phase']
      reply = line_reply(incoming)
      assert_equal 'reply', read_guide['phase']
      with_line_client(client) { Line::SendOnLineService.new(message: Message.find(reply.id)).perform }
      assert_equal 1, client.pushes.size
      assert reply.reload.delivered?
      assert_nil reply.source_id
      assert_equal 'complete', read_guide['phase']
      assert_equal incoming.conversation.display_id, read_guide['conversation_id']
    end
  end

  def test_line_invalid_webhook_and_private_or_bot_replies_do_not_finish_the_guide
    authenticated do
      inbox = line_inbox
      prepare_line(inbox)
      assert_nil receive_line(inbox, valid: false)
      assert_equal 'receive', read_guide['phase']
      incoming = receive_line(inbox)
      note = line_reply(incoming, private_note: true)
      note.update!(status: :delivered)
      bot = create(:agent_bot, account: @account)
      line_reply(incoming, sender: bot).update!(status: :delivered)
      assert_equal 'reply', read_guide['phase']
    end
  end

  def test_line_failed_or_empty_provider_response_never_completes_the_guide
    authenticated do
      inbox = line_inbox
      prepare_line(inbox)
      incoming = receive_line(inbox)
      [OpenStruct.new(code: '403', body: '{"message":"not permitted"}'), nil].each do |response|
        client = LineClient.new
        client.response = response
        reply = line_reply(incoming)
        with_line_client(client) { Line::SendOnLineService.new(message: Message.find(reply.id)).perform }
        assert_equal 1, client.pushes.size
        refute reply.reload.delivered?
        assert_equal 'reply', read_guide['phase']
      end
    end
  end

  def test_line_status_cannot_be_forged_through_message_creation_or_update
    authenticated do
      inbox = line_inbox
      prepare_line(inbox)
      incoming = receive_line(inbox)
      path = "/api/v1/accounts/#{@account.id}/conversations/#{incoming.conversation.display_id}/messages"
      post path, params: { content: '返信', status: 'delivered', message_type: 'outgoing' }, headers: @user.create_new_auth_token, as: :json
      assert_response :success
      reply = inbox.messages.outgoing.order(:id).last
      refute reply.delivered?
      patch "#{path}/#{reply.id}", params: { status: 'delivered' }, headers: @user.create_new_auth_token, as: :json
      assert_response :forbidden
      assert_equal 'reply', read_guide['phase']
    end
  end

  def test_line_requires_current_inbox_membership_for_staff
    authenticated do
      inbox = line_inbox
      prepare_line(inbox)
      @account.account_users.find_by!(user: @user).update!(role: 'agent')
      inbox.inbox_members.where(user: @user).delete_all
      assert_empty read_guide['inboxes']
      assert_equal 'connect', read_guide['phase']
      member = inbox.inbox_members.create!(user: @user)
      assert_equal [inbox.id], read_guide['inboxes'].pluck('id')
      member.destroy!
      assert_empty read_guide['inboxes']
    end
  end

  def test_line_and_mail_can_be_selected_without_exposing_another_store
    authenticated do
      mail = connect
      line = line_inbox
      foreign = line_inbox(create(:account))
      update_preference({ purpose: 'inbox' })
      assert_equal 'connect', read_guide['phase']
      assert_equal [mail.id, line.id], read_guide['inboxes'].pluck('id')
      update_preference({ inbox_id: line.id })
      assert_equal line.id, read_guide['inbox_id']
      update_preference({ inbox_id: foreign.id })
      assert_response :unprocessable_entity
      assert_equal line.id, read_guide['inbox_id']
      update_preference({ inbox_id: mail.id })
      assert_equal mail.id, read_guide['inbox_id']
    end
  end

  def test_removed_line_configuration_returns_to_connection_without_reusing_stored_preference
    authenticated do
      inbox = line_inbox
      prepare_line(inbox)
      inbox.channel.update_columns(line_channel_token: '')
      assert_equal 'connect', read_guide['phase']
      assert_empty read_guide['inboxes']
    end
  end

  def test_deleted_line_reply_does_not_claim_usable_first_reply
    authenticated do
      inbox = line_inbox
      prepare_line(inbox)
      reply = line_reply(receive_line(inbox))
      reply.update!(status: :delivered, content_attributes: { deleted: true })
      assert_equal 'reply', read_guide['phase']
    end
  end

end
