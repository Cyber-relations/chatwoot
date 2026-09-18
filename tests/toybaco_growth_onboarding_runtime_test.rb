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
end
