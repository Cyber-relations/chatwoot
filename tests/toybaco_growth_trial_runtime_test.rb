# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require 'ostruct'
require Rails.root.join('lib/toybaco/growth/trial_state')
require Rails.root.join('lib/toybaco/growth/bot_reply')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoGrowthTrialRuntimeTest < ActionDispatch::IntegrationTest
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true
  Growth = Toybaco::Growth
  Gmail = Toybaco::Connections::Gmail
  NOW = Time.utc(2026, 9, 19, 1)

  def setup
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    travel_to NOW
    @account = create(:account)
    @owner = create(:user, :administrator, account: @account)
    @account.update!(internal_attributes: { Toybaco::BillingAccess::OWNER_KEY => @owner.id })
    set_plan('free')
    @inbox = connect(@account)
    @bot = create(:agent_bot, account: @account)
    create(:agent_bot_inbox, inbox: @inbox, agent_bot: @bot)
    @conversation = create(:conversation, account: @account, inbox: @inbox, status: :pending).reload
    @incoming = create(:message, account: @account, inbox: @inbox, conversation: @conversation,
                                message_type: :incoming, private: false, content: '営業時間は？', source_id: 'trial-incoming@example.test')
    @facts = Growth::StoreFacts.new(@account).save!({ 'name' => 'テスト店舗', 'hours' => '10時から18時' }, user: @owner)
    @normal = Growth::AiGrants.new(@account).issue!(source: 'included', source_key: 'trial-example-fixture', units: 20,
                                                  starts_at: NOW - 1, ends_at: NOW + 30.days)
    Toybaco::AiReplyMode.write_to!(@account, 'draft')
    @example = example!
  end

  def teardown
    travel_back
    Current.reset
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  def set_plan(id)
    terms = Toybaco::PlanCatalog.default.definition(id, '2026-09-25.1')
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: id == 'free' ? nil : 'month'))
  end

  def connect(account, email: "trial-#{SecureRandom.hex(8)}@example.test")
    Gmail.connect!(account: account, tokens: { 'access_token' => 'fixture-access', 'refresh_token' => 'fixture-refresh', 'expires_in' => 3600 },
                   profile: { 'emailAddress' => email, 'historyId' => '100' })
  end

  def example!
    service = Growth::BotReply.new(@account, bot: @bot, conversation: @conversation, message: @incoming)
    reservation = service.update(action_type: 'reserve')
    result = service.update(action_type: 'consumed', operation_id: reservation['operation_id'], token: reservation['token'],
                            reply: '10時から18時までです。', mode: 'draft')
    assert_equal 'consumed', result['result']
    @account.messages.find(result.fetch('result_reference').delete_prefix('message:'))
  end

  def start!(user: @owner, confirmed: true, revision: @facts['revision'], example_id: @example.id)
    Gmail.stub(:allowed?, true) do
      Growth::TrialStart.new(@account, user).start!(example_id: example_id, revision: revision, confirmed: confirmed)
    end
  end

  def trial_grant
    Toybaco::GrowthAiGrant.find_by!(account_id: @account.id, source: 'trial')
  end

  def test_owner_start_is_once_and_does_not_consume_or_replace_normal_allowance
    assert_empty Toybaco::GrowthTrial.where(account_id: @account.id)
    first = start!
    assert_equal NOW, first.starts_at
    assert_equal NOW + 14.days, first.ends_at
    assert_equal 100, trial_grant.units
    assert_equal 1, @normal.reload.used
    travel_to NOW + 1.day
    assert_equal first.id, start!.id
    assert_equal first.ends_at, trial_grant.ends_at
    assert_equal 1, Toybaco::GrowthTrial.where(account_id: @account.id).count
    assert_equal 'auto', Toybaco::AiReplyMode.read_from(@account.reload)
    assert_nil @account.internal_attributes['toybaco_subscription_id']
    assert_equal [{ 'route' => 'trial', 'terms_version' => Toybaco::LegalTerms::VERSION, 'accepted_at' => NOW.iso8601,
                    'user_id' => @owner.id, 'session_id' => nil, 'stripe_consent' => nil }],
                 Toybaco::LegalTerms.records(@account), 'the already started trial does not add a second consent'
  end

  def test_explicit_confirmation_owner_and_current_example_are_required
    assert_raises(Growth::TrialStart::Unavailable) { start!(confirmed: false) }
    other = create(:user, :administrator, account: @account)
    assert_raises(Growth::TrialStart::Unavailable) { start!(user: other) }
    assert_raises(Growth::TrialStart::Unavailable) { start!(example_id: @incoming.id) }
    Growth::StoreFacts.new(@account).save!({ 'name' => '変更した店舗' }, user: @owner)
    assert_raises(Growth::TrialStart::Unavailable) { start! }
    assert_empty Toybaco::GrowthTrial.where(account_id: @account.id)
    assert_empty Toybaco::LegalTerms.records(@account.reload), 'a refused start records no consent'
  end

  def test_changed_latest_question_invalidates_the_answer_example
    @incoming.update!(content: '予約変更は？')
    assert_raises(Growth::TrialStart::Unavailable) { start! }
    assert_empty Toybaco::GrowthAiGrant.where(account_id: @account.id, source: 'trial')
  end

  def test_expired_connection_or_disabled_bot_cannot_start
    @inbox.channel.prompt_reauthorization!
    assert_raises(Growth::TrialStart::Unavailable) { start! }
    @inbox.channel.reauthorized!
    @inbox.agent_bot_inbox.update!(status: :inactive)
    assert_raises(Growth::TrialStart::Unavailable) { start! }
  end

  def test_trial_identity_contains_no_address_and_is_not_reissued_after_account_change
    trial = start!
    claim = trial.identities.first
    assert_match(/\A[0-9a-f]{64}\z/, claim.identity_digest)
    refute_includes claim.attributes.values.map(&:to_s).join, @inbox.channel.email
    assert_equal 'someone@gmail.com', Growth::TrialConnection.normalized_email('some.one+alias@googlemail.com')
    old_account_id = trial.account_id
    trial.update!(account_id: old_account_id + 1_000_000)
    assert_raises(Growth::TrialStart::Unavailable) { start! }
    assert_equal 1, Toybaco::GrowthAiGrant.where(account_id: @account.id, source: 'trial').count
    assert_nil Toybaco::GrowthTrial.find_by(account_id: old_account_id)
  end

  def test_trial_only_covers_the_confirmed_connection_identities
    start!
    Gmail.stub(:allowed?, true) { assert Growth::TrialConnection.allowed?(@account, @inbox.reload) }
    another = connect(@account)
    create(:agent_bot_inbox, inbox: another, agent_bot: @bot)
    Gmail.stub(:allowed?, true) { refute Growth::TrialConnection.allowed?(@account, another) }
  end

  def test_expiry_stops_automatic_and_preserves_messages_and_normal_allowance
    start!
    @conversation.pending!
    count = @conversation.messages.count
    travel_to NOW + 14.days
    Toybaco::GrowthTrialSweepJob.perform_now
    assert_equal 'draft', Toybaco::AiReplyMode.read_from(@account.reload)
    assert_equal 'open', @conversation.reload.status
    assert_equal count, @conversation.messages.count
    assert_equal 'expired', Toybaco::GrowthTrial.find_by!(account_id: @account.id).completion_reason
    assert trial_grant.revoked_at
    assert_equal 1, @normal.reload.used
    assert_equal 'completed', Growth::TrialState.new(@account).read['state']
  end

  def test_final_generation_may_dispatch_once_before_quota_end
    start!
    @conversation.pending!
    trial_grant.update!(used: 99)
    later = create(:message, account: @account, inbox: @inbox, conversation: @conversation,
                             message_type: :incoming, private: false, content: '明日も同じですか？', source_id: 'trial-second@example.test')
    service = Growth::BotReply.new(@account, bot: @bot, conversation: @conversation, message: later)
    Gmail.stub(:allowed?, true) do
      reservation = service.update(action_type: 'reserve')
      assert_equal 'reserved', reservation['result']
      result = service.update(action_type: 'consumed', operation_id: reservation['operation_id'], token: reservation['token'],
                              reply: '10時から18時までです。', mode: 'auto')
      assert_equal 'consumed', result['result']
      message = @account.messages.find(result['result_reference'].delete_prefix('message:'))
      Growth::TrialLifecycle.new(@account).refresh!
      assert_nil Toybaco::GrowthTrial.find_by!(account_id: @account.id).completed_at
      delivery = Growth::ReplyDelivery.new(message)
      assert delivery.claim!
      delivery.attempted!
      Growth::TrialLifecycle.new(@account).refresh!
      assert_equal 'limit_reached', Toybaco::GrowthTrial.find_by!(account_id: @account.id).completion_reason
      refute Growth::ReplyDelivery.new(message.reload).claim!
      assert_equal 100, trial_grant.used
    end
  end

  def test_paid_auto_rights_end_trial_without_adding_its_remainder
    start!
    trial_grant.update!(used: 7)
    set_plan('standard')
    Growth::TrialLifecycle.new(@account).refresh!
    assert_equal 'upgraded', Toybaco::GrowthTrial.find_by!(account_id: @account.id).completion_reason
    assert_equal 7, trial_grant.used
    assert trial_grant.revoked_at
    assert_equal 20, @normal.reload.units
    assert_equal 'auto', Toybaco::AiReplyMode.read_from(@account.reload)
    assert_equal 'included', Growth::TrialState.new(@account).read['state']
    assert_raises(Growth::TrialStart::Unavailable) { start! }
  end

  def test_real_start_api_and_owner_only_page
    input = { account_id: @account.id, example_id: @example.id, revision: @facts['revision'], confirmed: true }
    Gmail.stub(:allowed?, true) do
      Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @owner)) do
        get '/toybaco/growth/trial', params: { account_id: @account.id }
        assert_response :success
        assert_includes response.body, '10時から18時までです。'
        assert_includes response.body, 'Amazon Bedrock（東京・大阪）'
        assert_includes response.body, '受信箱の「AI応答」からいつでも停止できます。'
        assert_includes response.body, '上記と利用規約第7条の2を確認し、自動応答の体験を開始します'
        refute_includes response.body, 'この画面からいつでも停止できます', 'the trial page itself has no stop control'
        assert_empty Toybaco::GrowthTrial.where(account_id: @account.id)
        post '/toybaco/growth/trial', params: input, headers: { 'Origin' => 'https://elsewhere.test' }, as: :json
        assert_response :forbidden
        post '/toybaco/growth/trial', params: input, headers: { 'Origin' => 'http://www.example.com' }, as: :json
        assert_response :success
        assert_equal 'active', response.parsed_body['state']
        assert_equal 100, response.parsed_body['remaining']
        get '/toybaco/growth/trial', params: { account_id: @account.id }
        assert_response :success
        assert_includes response.body, '2026年10月3日'
        get '/toybaco/growth/trial', params: { account_id: create(:account).id }
        assert_response :forbidden
      end
    end
  end
end
