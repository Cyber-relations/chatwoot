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
    GlobalConfig.clear_cache
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

  def test_pages_and_refusals_name_the_mail_inbox_the_bot_and_the_review
    input = { account_id: @account.id, example_id: @example.id, revision: @facts['revision'], confirmed: true }
    Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @owner)) do
      # Until the provider's review is recorded the Gmail inbox cannot run the trial, so its draft is not offered.
      get '/toybaco/growth/trial', params: { account_id: @account.id }
      assert_response :success
      assert_includes response.body, 'トイバコで接続した Gmail または Microsoft のメール受信箱で、14日間・100回まで。カード登録は不要です。'
      # The mail connection opens only after the review, so the page does not ask to connect it now.
      assert_includes response.body, '<p>メールの接続は提供元の審査完了後に順次開放します。開放されたら、トイバコで Gmail または Microsoft の' \
                                     'メール受信箱を接続し、ボット設定で「トイバコAI」を割り当ててください。店舗情報を設定したうえで、その受信箱で' \
                                     'AIの下書きを1件作成してください。LINE・Webチャットで作った下書きは体験の対象外です。</p>'
      assert_includes response.body, '体験に使った Gmail・Microsoft のアカウントは、別の店舗の体験には使えません。'
      refute_includes response.body, 'id="trial-form"'
      post '/toybaco/growth/trial', params: input, headers: { 'Origin' => 'http://www.example.com' }, as: :json
      assert_response :unprocessable_entity
      assert_equal '回答例を作った受信箱では体験を開始できません。体験は、トイバコで接続した Gmail または Microsoft の受信箱のうち、' \
                   'ボット設定で「トイバコAI」を割り当てたものが対象です。接続の期限が切れている場合は再接続してください。' \
                   'メールの接続は提供元の審査完了後に開放します。', response.parsed_body['error']
      Gmail.stub(:allowed?, true) do
        get '/toybaco/growth/trial', params: { account_id: @account.id }
        assert_includes response.body, 'id="trial-form"'
        assert_includes response.body, '開始すると、接続済みの対象受信箱（トイバコで接続した Gmail または Microsoft のメール受信箱で、' \
                                       'ボット設定で「トイバコAI」を割り当て済みのもの）でAIが返信します。それ以外の受信箱（LINE・Webチャットなど）は対象外です。'
        refute_includes response.body, 'LINE・Webチャットで作った下書き'
      end
      get "/toybaco/billing?account_id=#{@account.id}"
      assert_response :success
      # The card says when the 14 days start and which inboxes count; the badge keeps the higher plan as the other way.
      assert_includes response.body, 'オーナーが開始してから14日間または100回の早い方までです。対象は、トイバコで接続した Gmail または Microsoft の' \
                                     'メール受信箱だけです。カード登録は不要です。メールの接続は提供元の審査完了後に開放します。'
      assert_includes response.body, '審査完了後に体験できます（上位プランでも利用できます）'
      refute_includes response.body, '接続後、14日間'
      refute_includes response.body, 'お知らせします'
      # The AI panel adds the trial condition only for a contract without automatic replies.
      get '/toybaco/ai_usage', params: { account_id: @account.id }
      assert_response :success
      assert_equal false, response.parsed_body['automatic_included']
    end
    other = create(:user, :administrator, account: @account)
    assert_equal NOT_OWNER, start_refusal(user: other)
    assert_equal '現在の店舗情報と最新の問い合わせで作成した回答例が必要です。画面を更新して回答例を選び直してください。' \
                 '表示されない場合は、ボット設定で「トイバコAI」を割り当てた Gmail または Microsoft の受信箱で、AIの下書きを1件作成してください。',
                 start_refusal(confirmed: false)
    start!.update!(account_id: @account.id + 1_000_000)
    assert_equal '接続中の Gmail・Microsoft の受信箱に、別の店舗の体験で使ったものがあります。体験は同じ接続先につき1回です。' \
                 '元の店舗をご利用いただくか、Standard以上のプランをご検討ください。', start_refusal
    # toybaco-growth-trial.js shows a refusal reason only up to 160 characters.
    Growth::TrialStart::MESSAGES.each_value { |message| assert_operator message.length, :<=, 160, message }
  end

  # Each refusal names its own cause. The checks keep their order: store, email confirmation, contract owner, plan.
  INACTIVE = 'この店舗はいま利用できない状態です。サポートへお問い合わせください。'
  UNCONFIRMED = 'メールアドレスの確認が終わってから開始できます。確認を完了して、もう一度お試しください。'
  NOT_OWNER = '体験を開始できるのは、この店舗の契約者です。契約者に開始を依頼してください。'
  INCLUDED = 'このプランでは自動応答が契約に含まれています。受信箱の「AI応答」から設定してください。'

  def start_refusal(**changes)
    assert_raises(Growth::TrialStart::Unavailable) { start!(**changes) }.message
  end

  def test_refusal_for_an_inactive_store_comes_first
    @account.update_columns(status: Account.statuses[:suspended])
    assert_equal INACTIVE, start_refusal
    @owner.update_columns(confirmed_at: nil)
    assert_equal INACTIVE, start_refusal
    assert_empty Toybaco::GrowthTrial.where(account_id: @account.id)
  end

  def test_refusal_for_an_unconfirmed_email_comes_before_the_owner_check
    @owner.update_columns(confirmed_at: nil)
    assert_equal UNCONFIRMED, start_refusal
    other = create(:user, :administrator, account: @account)
    other.update_columns(confirmed_at: nil)
    assert_equal UNCONFIRMED, start_refusal(user: other)
    assert_empty Toybaco::GrowthTrial.where(account_id: @account.id)
  end

  def test_refusal_for_a_plan_with_automatic_replies_comes_after_the_owner_check_and_the_page_drops_the_trial_lead
    set_plan('standard')
    assert_equal INCLUDED, start_refusal
    assert_equal NOT_OWNER, start_refusal(user: create(:user, :administrator, account: @account))
    Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @owner)) do
      get '/toybaco/ai_usage', params: { account_id: @account.id }
      assert_equal true, response.parsed_body['automatic_included']
      get '/toybaco/growth/trial', params: { account_id: @account.id }
    end
    assert_response :success
    assert_includes response.body, '自動応答はご契約に含まれています'
    refute_includes response.body, '14日間・100回まで'
    refute_includes response.body, 'class="lead"'
  end

  def test_refusal_for_a_contract_outside_the_new_pricing_names_the_trial_plans
    terms = Toybaco::PlanCatalog.default.definition('light', '2026-09-06.1')
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: 'month'))
    assert_equal '体験は、2026年9月25日改定の新料金プランの無料プラン・ライトで開始できます。' \
                 '現在のご契約では対象外です。ご契約内容をご確認ください。', start_refusal
  end

  def test_second_start_racing_in_the_same_store_asks_to_reload
    start!
    # A start that missed the first one's row hits the store's own unique index, not the connection's: it must not
    # say that another store used the inbox.
    refusal = Toybaco::GrowthTrial.stub(:find_by, nil) { start_refusal }
    assert_equal '開始状況を確認できませんでした。画面を更新して確認してください。', refusal
    assert_equal 1, Toybaco::GrowthTrial.where(account_id: @account.id).count
  end

  def test_connection_lost_between_the_two_reads_asks_to_connect_and_assign_the_bot
    original = Growth::TrialConnection.method(:identity)
    reads = 0
    expiring = lambda do |inbox|
      # The mailbox asks for reauthorization after the draft's inbox was read and before the store's inboxes are.
      @inbox.channel.prompt_reauthorization! if (reads += 1) == 2
      original.call(inbox)
    end
    refusal = Growth::TrialConnection.stub(:identity, expiring) { start_refusal }
    assert_equal 'Gmail または Microsoft の受信箱を接続し、ボット設定で「トイバコAI」を割り当ててください。', refusal
    assert_equal 2, reads
    assert_empty Toybaco::GrowthTrial.where(account_id: @account.id)
  ensure
    @inbox.channel.reauthorized!
  end

  def test_empty_state_once_the_mail_connection_opens_does_not_ask_to_wait
    # The draft no longer answers the latest question, so no answer example is offered.
    @incoming.update!(content: '予約変更は？')
    [Gmail, Toybaco::Connections::Microsoft].each do |provider|
      Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @owner)) do
        provider.stub(:allowed?, true) { get '/toybaco/growth/trial', params: { account_id: @account.id } }
      end
      assert_response :success
      assert_includes response.body, '<p>トイバコで Gmail または Microsoft のメール受信箱を接続し、ボット設定で「トイバコAI」を割り当ててください。' \
                                     '店舗情報を設定したうえで、その受信箱でAIの下書きを1件作成してください。LINE・Webチャットで作った下書きは体験の対象外です。</p>',
                      provider.name
      refute_includes response.body, '審査完了後', provider.name
      refute_includes response.body, 'id="trial-form"', provider.name
    end
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

  # U2: the Lambda may answer a store outside its static list only when Rails allows the inbox. The same predicate
  # decides the reservation, so the two answers agree in every trial state.
  def enable_bot_access
    record = InstallationConfig.find_or_initialize_by(name: 'TOYBACO_GROWTH_BOT_ACCESS_ENABLED')
    record.value = true
    record.save!
    GlobalConfig.clear_cache
  end

  def bot_headers
    { 'api_access_token' => @bot.access_token.token }
  end

  def bot_access(inbox)
    get '/toybaco/ai_reply_mode', params: { account_id: @account.id, inbox_id: inbox.id }, headers: bot_headers
    assert_response :success
    response.parsed_body['access']
  end

  # A new customer question in a pending conversation of the inbox, reserved through the bot API.
  def bot_reserve(inbox)
    conversation = create(:conversation, account: @account, inbox: inbox, status: :pending)
    message = create(:message, account: @account, inbox: inbox, conversation: conversation, message_type: :incoming,
                               private: false, content: '明日は営業していますか？', source_id: "bot-access-#{SecureRandom.hex(6)}@example.test")
    post '/toybaco/ai_usage', params: { account_id: @account.id, conversation_id: conversation.display_id, message_id: message.id,
                                        action_type: 'reserve' }, headers: bot_headers, as: :json
    assert_response :success
    response.parsed_body
  end

  def assert_denied_both(reason, inbox = @inbox)
    assert_equal({ 'allowed' => false, 'reason' => reason }, bot_access(inbox))
    assert_equal({ 'result' => 'denied', 'reason' => 'trial_connection_unavailable' }, bot_reserve(inbox), "reservation for #{reason}")
  end

  # start! stubs the same review check itself, so it is called outside this block (minitest stubs do not nest).
  def reviewed(&)
    Gmail.stub(:allowed?, true, &)
  end

  def test_bot_access_and_the_reservation_agree_in_every_trial_state
    enable_bot_access
    Toybaco::AiReplyMode.write_to!(@account, 'auto')
    reviewed { assert_denied_both('trial_not_started') }
    trial = start!
    reviewed do
      assert_equal({ 'allowed' => true, 'reason' => 'trial' }, bot_access(@inbox))
      assert_equal 'reserved', bot_reserve(@inbox)['result']
      # A mailbox connected after the start is not one of the trial's connections, though the bot is on it.
      another = connect(@account)
      create(:agent_bot_inbox, inbox: another, agent_bot: @bot)
      assert_denied_both('connection_not_covered', another)
      trial.update!(completed_at: NOW, completion_reason: 'expired')
      assert_denied_both('trial_ended')
      trial.update!(completed_at: nil, completion_reason: nil)
      assert_equal 'trial', bot_access(@inbox)['reason']
      travel_to trial.ends_at
      assert_denied_both('trial_ended')
    end
  end

  def test_bot_access_keeps_the_mail_provider_review_requirement
    enable_bot_access
    start!
    # Outside the review release the Gmail connection has no trial identity, so neither path is open.
    refute Gmail.allowed?(@account)
    assert_denied_both('connection_not_covered')
    reviewed { assert_equal({ 'allowed' => true, 'reason' => 'trial' }, bot_access(@inbox)) }
  end
end
