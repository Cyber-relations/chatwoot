# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require 'ostruct'
require 'timeout'
require Rails.root.join('lib/toybaco/growth/trial_state')
require Rails.root.join('lib/toybaco/growth/bot_reply')
require Rails.root.join('lib/toybaco/growth/onboarding')

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

  def example!(conversation: @conversation, incoming: @incoming)
    service = Growth::BotReply.new(@account, bot: @bot, conversation: conversation, message: incoming)
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
      assert_includes response.body, '<p class="lead">IMAP で接続したメール受信箱で、14日間・100回まで。カード登録は不要です。</p>'
      # The direct Gmail / Microsoft connections open only after the review, so the page asks to connect a mailbox over IMAP now.
      assert_includes response.body, '<p>Gmail / Microsoft の直接接続は提供元の審査完了後に開放します。トイバコでメール受信箱を接続' \
                                     '（「その他のプロバイダー」で IMAP を有効化）し、ボット設定で「トイバコAI」を割り当ててください。店舗情報を設定したうえで、' \
                                     'その受信箱でAIの返信案を1件作成してください。LINE・Webチャットで作った下書きは体験の対象外です。</p>'
      assert_includes response.body, '体験に使ったメールアドレス（Gmail・Microsoft のアカウントを含む）は、別の店舗の体験には使えません。'
      refute_includes response.body, 'id="trial-form"'
      post '/toybaco/growth/trial', params: input, headers: { 'Origin' => 'http://www.example.com' }, as: :json
      assert_response :unprocessable_entity
      assert_equal '回答例を作った受信箱では体験を開始できません。体験は、IMAP で接続したメール受信箱のうち、' \
                   'ボット設定で「トイバコAI」を割り当てたものが対象です。接続の期限が切れている場合は再接続してください。' \
                   'Gmail / Microsoft の直接接続は提供元の審査完了後に開放します。', response.parsed_body['error']
      Gmail.stub(:allowed?, true) do
        get '/toybaco/growth/trial', params: { account_id: @account.id }
        assert_includes response.body, 'id="trial-form"'
        assert_includes response.body, '開始すると、接続済みの対象受信箱（IMAP で接続したメール受信箱、または Gmail の直接接続で、' \
                                       'ボット設定で「トイバコAI」を割り当て済みのもの）でAIが返信します。それ以外の受信箱（LINE・Webチャットなど）は対象外です。'
        refute_includes response.body, 'LINE・Webチャットで作った下書き'
      end
      get "/toybaco/billing?account_id=#{@account.id}"
      assert_response :success
      # The card says when the 14 days start and which inboxes count; the badge keeps the higher plan as the other way.
      assert_includes response.body, 'オーナーが開始してから14日間または100回の早い方までです。対象は、IMAP で接続したメール受信箱だけです。' \
                                     'カード登録は不要です。Gmail / Microsoft の直接接続は提供元の審査完了後に開放します。'
      assert_includes response.body, 'IMAP で接続したメール受信箱で体験できます（上位プランでも利用できます）'
      refute_includes response.body, '接続後、14日間'
      refute_includes response.body, 'お知らせします'
      # The AI panel adds the trial condition only for a contract without automatic replies.
      get '/toybaco/ai_usage', params: { account_id: @account.id }
      assert_response :success
      assert_equal false, response.parsed_body['automatic_included']
    end
    other = create(:user, :administrator, account: @account)
    assert_equal NOT_OWNER, start_refusal(user: other)
    # start! opens only the Gmail connection, so the outdated-example refusal names Gmail beside the IMAP mailbox; the
    # used-elsewhere refusal names no connection, as one mail address starts one trial (every release is fixed below).
    assert_equal '現在の店舗情報と最新の問い合わせで作成した回答例が必要です。画面を更新して回答例を選び直してください。' \
                 '表示されない場合は、ボット設定で「トイバコAI」を割り当てた、IMAP で接続したメール受信箱（または Gmail の直接接続）' \
                 'で、AIの下書きを1件作成してください。',
                 start_refusal(confirmed: false)
    start!.update!(account_id: @account.id + 1_000_000)
    assert_equal '接続中のメール受信箱に、別の店舗の体験で使ったものがあります。体験は同じメールアドレスにつき1回です。' \
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
    # start! opens only the Gmail connection, so the refusal names Gmail alone as the direct connection.
    assert_equal 'メール受信箱を IMAP で接続（開放済みなら Gmail の直接接続も可）し、ボット設定で「トイバコAI」を割り当ててください。', refusal
    assert_equal 2, reads
    assert_empty Toybaco::GrowthTrial.where(account_id: @account.id)
  ensure
    @inbox.channel.reauthorized!
  end

  # B2: the mail connections a store may use follow each connection's release for that store (allowed?). An IMAP mailbox
  # needs no review, so the pages always name it. Until a direct connection opens they keep the review sentence; once one
  # opens they add only the opened connections and drop the review sentence.
  RELEASES = { [false, false] => [], [true, false] => ['Gmail'], [false, true] => ['Microsoft'],
               [true, true] => %w[Gmail Microsoft] }.freeze
  IMAP_LABEL = 'IMAP で接続したメール受信箱'
  REVIEW = 'Gmail / Microsoft の直接接続は提供元の審査完了後に開放します。'

  def with_released(gmail, microsoft, &block)
    Gmail.stub(:allowed?, gmail) { Toybaco::Connections::Microsoft.stub(:allowed?, microsoft, &block) }
  end

  # The trial's mailboxes as the pages name them: the IMAP mailbox, then any opened direct connection.
  def available_label(released)
    released.empty? ? IMAP_LABEL : "#{IMAP_LABEL}、または #{released.join(' / ')} の直接接続"
  end

  def test_empty_state_names_only_the_opened_mail_connections_and_asks_to_wait_until_one_opens
    # The draft no longer answers the latest question, so no answer example is offered.
    @incoming.update!(content: '予約変更は？')
    guide = '）し、ボット設定で「トイバコAI」を割り当ててください。店舗情報を設定したうえで、その受信箱でAIの返信案を1件作成してください。' \
            'LINE・Webチャットで作った下書きは体験の対象外です。</p>'
    RELEASES.each do |(gmail, microsoft), released|
      with_released(gmail, microsoft) do
        Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @owner)) { get '/toybaco/growth/trial', params: { account_id: @account.id } }
      end
      assert_response :success
      direct = released.empty? ? '' : "、または #{released.join(' / ')} の直接接続"
      head = "<p>#{REVIEW if released.empty?}トイバコでメール受信箱を接続（「その他のプロバイダー」で IMAP を有効化#{direct}"
      assert_includes response.body, head + guide, released.inspect
      assert_includes response.body, "<p class=\"lead\">#{available_label(released)}で、14日間・100回まで。カード登録は不要です。</p>"
      assert_equal released.empty?, response.body.include?('審査完了後'), released.inspect
      refute_includes response.body, 'id="trial-form"', released.inspect
    end
  end

  # The refusals that name the opened direct connections, with %s for the names joined by 「 / 」 (no doubled 「または」).
  # The IMAP mailbox comes first in each.
  REFUSALS = {
    'example_outdated' => '現在の店舗情報と最新の問い合わせで作成した回答例が必要です。画面を更新して回答例を選び直してください。' \
                          '表示されない場合は、ボット設定で「トイバコAI」を割り当てた、IMAP で接続したメール受信箱（または %s の直接接続）' \
                          'で、AIの下書きを1件作成してください。',
    'example_inbox' => '回答例を作った受信箱では体験を開始できません。体験は、IMAP で接続したメール受信箱（開放済みなら %s の直接接続も）' \
                       'のうち、ボット設定で「トイバコAI」を割り当てたものが対象です。接続の期限が切れている場合は再接続してください。',
    'no_mail_inbox' => 'メール受信箱を IMAP で接続（開放済みなら %s の直接接続も可）し、ボット設定で「トイバコAI」を割り当ててください。'
  }.freeze
  # Until a direct connection opens, example_inbox adds the review sentence and drops the bracket (the two say the same,
  # and together they would pass the 160 characters the start screen shows).
  WAITING_EXAMPLE_INBOX = '回答例を作った受信箱では体験を開始できません。体験は、IMAP で接続したメール受信箱のうち、' \
                          'ボット設定で「トイバコAI」を割り当てたものが対象です。接続の期限が切れている場合は再接続してください。' + REVIEW
  # Until a direct connection opens, these refusals name no connection (no_mail_inbox adds the review sentence).
  WAITING_REFUSALS = {
    'example_outdated' => '現在の店舗情報と最新の問い合わせで作成した回答例が必要です。画面を更新して回答例を選び直してください。' \
                          '表示されない場合は、ボット設定で「トイバコAI」を割り当てた、IMAP で接続したメール受信箱で、AIの下書きを1件作成してください。',
    'example_inbox' => WAITING_EXAMPLE_INBOX,
    'no_mail_inbox' => '「その他のプロバイダー」で IMAP を有効化したメール受信箱を接続し、ボット設定で「トイバコAI」を割り当ててください。' + REVIEW
  }.freeze
  # The refusals that name no connection read the same whether or not a direct connection is open.
  FIXED_REFUSALS = {
    'used_elsewhere' => '接続中のメール受信箱に、別の店舗の体験で使ったものがあります。体験は同じメールアドレスにつき1回です。' \
                        '元の店舗をご利用いただくか、Standard以上のプランをご検討ください。',
    'imap_unverified' => 'メール受信箱の IMAP ログインを確認できませんでした。受信箱の設定（IMAP のホスト・ポート・ログイン・パスワード）を確認して、' \
                         'もう一度お試しください。',
    'imap_rule_mismatch' => 'Gmail のアドレスは imap.gmail.com で IMAP を有効化した受信箱だけが対象です。転送だけの受信箱は対象外です。' \
                            '受信箱の接続方法を確認してください。'
  }.freeze

  # The refusal for key: the fixed text when it names no connection, the waiting text until a direct connection opens,
  # otherwise the text with the opened connections' names.
  def expected_refusal(key, released)
    return FIXED_REFUSALS.fetch(key) if FIXED_REFUSALS.key?(key)
    return WAITING_REFUSALS.fetch(key) if released.empty?

    format(REFUSALS.fetch(key), released.join(' / '))
  end

  def test_every_refusal_names_only_the_opened_mail_connections_and_keeps_the_waiting_wording_until_one_opens
    trial = Growth::TrialStart.new(@account, @owner)
    RELEASES.slice([false, false], [true, false], [true, true]).each do |(gmail, microsoft), released|
      with_released(gmail, microsoft) do
        FIXED_REFUSALS.merge(REFUSALS).each_key do |key|
          expected = expected_refusal(key, released)
          assert_equal expected, trial.send(:message, key), [key, released].inspect
          assert_operator expected.length, :<=, 160, expected
          assert_equal expected, Growth::TrialStart::MESSAGES.fetch(key) if released.empty?
        end
        assert_equal Growth::TrialStart::MESSAGES.fetch('start_unconfirmed'), trial.send(:message, 'start_unconfirmed')
      end
    end
  end

  def test_billing_trial_refusal_and_usage_name_only_the_opened_mail_connections
    # The example's inbox needs reconnecting, so the start is refused for that inbox whether or not a connection is open.
    @inbox.channel.prompt_reauthorization!
    card = 'オーナーが開始してから14日間または100回の早い方までです。対象は、%sだけです。カード登録は不要です。'
    RELEASES.slice([false, false], [true, false], [true, true]).each do |(gmail, microsoft), released|
      with_released(gmail, microsoft) do
        Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @owner)) do
          get "/toybaco/billing?account_id=#{@account.id}"
          assert_includes response.body, "#{format(card, available_label(released))}#{REVIEW if released.empty?}</p>", released.inspect
          # The trial no longer waits for the review, so the badge names the trial's mailboxes in every state.
          assert_includes response.body, "#{available_label(released)}で体験できます（上位プランでも利用できます）"
          assert_equal released.empty?, response.body.include?('審査完了後'), released.inspect
          get '/toybaco/ai_usage', params: { account_id: @account.id }
          assert_equal released, response.parsed_body['trial_connections']
        end
        message = assert_raises(Growth::TrialStart::Unavailable) do
          Growth::TrialStart.new(@account, @owner).start!(example_id: @example.id, revision: @facts['revision'], confirmed: true)
        end.message
        assert_equal expected_refusal('example_inbox', released), message
        assert_operator message.length, :<=, 160, message
      end
    end
    assert_empty Toybaco::GrowthTrial.where(account_id: @account.id)
  ensure
    @inbox.channel.reauthorized!
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
        assert_includes response.body, '受信箱の「AI返信の設定」からいつでも停止できます。'
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

  IMAP_PASSWORD = 'imap-fixture-password'

  # A standard mail inbox that receives over IMAP (IMAP on, signed in as login on host), with the bot assigned.
  # With imap_enabled: false it only receives forwarded mail, so its address is whatever someone typed.
  def mail_inbox!(address: "shop-#{SecureRandom.hex(6)}@example.test", login: address, host: 'imap.example.test', imap_enabled: true)
    imap = if imap_enabled
             { imap_enabled: true, imap_login: login, imap_password: IMAP_PASSWORD, imap_address: host, imap_port: 993 }
           else
             { imap_enabled: false }
           end
    inbox = @account.inboxes.create!(channel: Channel::Email.create!(account: @account, email: address, **imap), name: address)
    create(:agent_bot_inbox, inbox: inbox, agent_bot: @bot)
    inbox
  end

  # A current answer example in the inbox, drafted the same way as the fixture's (example!).
  def example_in!(inbox)
    conversation = create(:conversation, account: @account, inbox: inbox, status: :pending).reload
    incoming = create(:message, account: @account, inbox: inbox, conversation: conversation, message_type: :incoming, private: false,
                                content: '営業時間は？', source_id: "mail-#{SecureRandom.hex(6)}@example.test")
    example!(conversation: conversation, incoming: incoming)
  end

  # TrialStart#start! without the review stub that start! adds.
  def start_with(example)
    Growth::TrialStart.new(@account, @owner).start!(example_id: example.id, revision: @facts['revision'], confirmed: true)
  end

  # An Instagram inbox with the bot assigned. Its channel can ask for reauthorization too, but it is not a mail inbox.
  # The subscription HTTP to Meta at creation is not called in the test.
  def instagram_inbox!
    channel = HTTParty.stub(:post, nil) do
      Channel::Instagram.create!(account: @account, instagram_id: "ig-#{SecureRandom.hex(8)}", access_token: 'instagram-fixture-token',
                                 expires_at: 60.days.from_now)
    end
    create(:agent_bot_inbox, inbox: @account.inboxes.create!(channel: channel, name: 'テスト店舗 Instagram'), agent_bot: @bot).inbox
  end

  # Net::IMAP stand-in for Toybaco's sign-in check (ImapVerification): the sign-in succeeds, or answers NO when rejected or
  # when accepted names the only login the server knows. With logout_error (an exception class) the logout after the
  # sign-in raises it.
  FakeImap = Struct.new(:rejected, :disconnected, :accepted, :logout_error) do
    def authenticate(_mechanism, user, _password)
      sign_in(user)
    end

    def login(user, _password)
      sign_in(user)
    end

    def logout
      raise logout_error, 'IMAP fixture' if logout_error

      nil
    end

    def disconnect
      self.disconnected = true
    end

    def disconnected?
      disconnected == true
    end

    private

    def sign_in(user)
      return unless rejected || (accepted && user != accepted)

      raise Net::IMAP::NoResponseError, OpenStruct.new(data: OpenStruct.new(text: 'Invalid credentials'))
    end
  end

  # Runs the block with Net::IMAP.new replaced and returns the connections it opened ([host, options]). :accept signs in,
  # :reject answers NO, and an exception class is raised while connecting. No test reaches the network.
  def with_imap(outcome = :accept)
    connections = []
    opener = lambda do |host, **options|
      connections << [host, options]
      raise outcome, 'IMAP fixture' if outcome.is_a?(Class)

      FakeImap.new(outcome == :reject)
    end
    Net::IMAP.stub(:new, opener) { yield connections }
    connections
  end

  def imap_record(inbox)
    inbox.channel.reload.provider_config['toybaco_imap_verified']
  end

  # Runs the block with @account's with_lock (TrialStart's store lock) tracked and Net::IMAP.new raising while it is held:
  # Toybaco signs in before it takes the store's lock, never inside. The sign-in succeeds (or answers NO when rejected or
  # when accepted names the only login the server knows); on_lock runs as the lock is taken, on_connect as Net::IMAP.new
  # is called, and logout is an exception class that the logout after the sign-in raises. Returns the connections.
  def with_imap_outside_the_store_lock(outcome = :accept, accepted: nil, on_lock: nil, on_connect: nil, logout: nil)
    depth = [0]
    marker = Module.new do
      define_method(:with_lock) do |*args, **options, &block|
        super(*args, **options) do
          depth[0] += 1
          on_lock&.call if depth[0] == 1
          block.call
        ensure
          depth[0] -= 1
        end
      end
    end
    @account.singleton_class.prepend(marker)
    connections = []
    opener = lambda do |host, **options|
      raise 'Net::IMAP.new inside the store lock' if depth[0].positive?

      connections << [host, options]
      on_connect&.call
      FakeImap.new(outcome == :reject, nil, accepted, logout)
    end
    Net::IMAP.stub(:new, opener) { yield }
    connections
  end

  # The page offers the IMAP mailbox's drafts after one sign-in to it; the Gmail connection's draft still waits for the review.
  def test_the_trial_page_offers_the_imap_mailbox_draft_while_the_gmail_connection_waits
    inbox = mail_inbox!
    drafts = [example_in!(inbox), example_in!(inbox)]
    connections = with_imap do
      Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @owner)) { get '/toybaco/growth/trial', params: { account_id: @account.id } }
    end
    assert_response :success
    # One sign-in for the mailbox on a page, though two of its drafts are offered.
    assert_equal [['imap.example.test', { port: 993, ssl: true, open_timeout: 8 }]], connections
    assert_includes response.body, '<p class="lead">IMAP で接続したメール受信箱で、14日間・100回まで。カード登録は不要です。</p>'
    drafts.each { |draft| assert_includes response.body, %(value="#{draft.id}") }
    refute_includes response.body, %(value="#{@example.id}")
    assert_includes response.body, '開始すると、接続済みの対象受信箱（IMAP で接続したメール受信箱で、ボット設定で「トイバコAI」を割り当て済みのもの）でAIが返信します。'
  end

  # Toybaco signed in to the IMAP mailbox, so the trial starts there while Gmail / Microsoft wait for their review. The
  # store's Instagram inbox with the bot has no trial identity and does not stop the start.
  def test_an_imap_mailbox_starts_the_trial_without_the_provider_review
    inbox = mail_inbox!
    assert_nil Growth::TrialConnection.identity(instagram_inbox!)
    refute Gmail.allowed?(@account)
    # Without a trial the bot's checks do not sign in to the mailbox.
    assert_empty(with_imap { refute Growth::TrialConnection.allowed?(@account, inbox) })
    trial = nil
    with_imap { trial = start_with(example_in!(inbox)) }
    assert_equal ['imap'], trial.identities.pluck(:provider)
    # The trial's checks reuse the sign-in recorded at the start instead of connecting again.
    assert_empty(with_imap { assert Growth::TrialConnection.allowed?(@account, inbox.reload) })
    refute Growth::TrialConnection.allowed?(@account, @inbox)
    assert_equal 100, trial_grant.units
    assert_equal ['trial'], Toybaco::LegalTerms.records(@account.reload).pluck('route')
  end

  # A forwarding-only inbox (IMAP off) proves nothing about who owns the address: no trial identity, and no sign-in to it.
  # The refusal asks to check how the inbox is connected (imap_rule_mismatch).
  def test_a_forwarding_only_mail_inbox_has_no_trial_identity_and_cannot_start
    forwarding = mail_inbox!(imap_enabled: false)
    forwarded_example = example_in!(forwarding)
    connections = with_imap do
      assert_nil Growth::TrialConnection.identity(forwarding)
      assert_equal Growth::TrialStart::MESSAGES.fetch('imap_rule_mismatch'),
                   assert_raises(Growth::TrialStart::Unavailable) { start_with(forwarded_example) }.message
      # IMAP switched on without a login is not a sign-in either.
      forwarding.channel.update!(imap_enabled: true, imap_login: ' ')
      assert_nil Growth::TrialConnection.identity(forwarding.reload)
    end
    assert_empty connections
    assert_empty Toybaco::GrowthTrial.where(account_id: @account.id)
    assert_empty Toybaco::LegalTerms.records(@account.reload)
  end

  # An IMAP mailbox that Chatwoot asks to reauthorize is not a trial connection until it is reconnected.
  def test_an_imap_mailbox_that_needs_reauthorization_has_no_trial_identity
    inbox = mail_inbox!
    with_imap { assert_equal 'imap', Growth::TrialConnection.identity(inbox)[:provider] }
    inbox.channel.prompt_reauthorization!
    assert_nil Growth::TrialConnection.identity(inbox.reload)
  ensure
    inbox&.channel&.reauthorized!
  end

  # A Gmail address signed in on Google's IMAP is the same mailbox as the Gmail API connection, so it is the same 'gmail'
  # identity (the identities' unique index is provider and digest): one trial per mailbox. The Gmail API reports the
  # account's own address; an IMAP login may add dots, a +tag or capitals, or use googlemail.com. Chatwoot keeps one
  # inbox per exact address, so the connections below use spellings of the same mailbox.
  def test_a_gmail_address_on_google_imap_is_the_same_identity_as_the_gmail_api_connection
    imap = nil
    connections = with_imap do
      imap = Growth::TrialConnection.identity(mail_inbox!(address: 'Shop.Name+tag@gmail.com', host: 'imap.gmail.com'))
      # The host is compared without case.
      assert_equal imap, Growth::TrialConnection.identity(mail_inbox!(address: 'shopname@googlemail.com', host: 'IMAP.Gmail.com'))
    end
    # Toybaco connects to the host as it compares it (lower case, no trailing dot).
    assert_equal %w[imap.gmail.com imap.gmail.com], connections.map(&:first)
    assert_equal 'gmail', imap[:provider]
    other = create(:account)
    api_inbox = connect(other, email: 'shop.name@gmail.com')
    create(:agent_bot_inbox, inbox: api_inbox, agent_bot: create(:agent_bot, account: other))
    assert_equal imap, Gmail.stub(:allowed?, true) { Growth::TrialConnection.identity(api_inbox) }
  end

  # Anyone can name a Gmail address on a host of their own, so a Gmail address outside Google's IMAP is not a trial
  # connection (it would otherwise take the Gmail owner's one trial). It is excluded before any sign-in, and the refusal
  # asks to check how the inbox is connected (imap_rule_mismatch).
  def test_a_gmail_address_on_another_imap_host_has_no_trial_identity_and_cannot_start
    inbox = mail_inbox!(address: 'shop.name@gmail.com', host: 'imap.example.test')
    gmail_example = example_in!(inbox)
    connections = with_imap do
      assert_nil Growth::TrialConnection.identity(inbox)
      refute Growth::TrialConnection.ready?(inbox)
      assert_nil Growth::TrialConnection.identity(mail_inbox!(address: 'shop.name+x@gmail.com', host: 'imap.gmail.com.example.test'))
      assert_equal Growth::TrialStart::MESSAGES.fetch('imap_rule_mismatch'),
                   assert_raises(Growth::TrialStart::Unavailable) { start_with(gmail_example) }.message
      # The Gmail API connection waiting for its review is not a rule mismatch; its refusal stays the general one.
      refute Growth::TrialConnection.imap_rule_mismatch?(@inbox)
    end
    assert_empty connections
    assert_empty Toybaco::GrowthTrial.where(account_id: @account.id)
  end

  # Another address counts as 'imap' together with its host, so naming someone's address on another host does not
  # match the identity of their own mailbox.
  def test_another_address_counts_as_imap_together_with_its_host
    own = elsewhere = nil
    with_imap do
      own = Growth::TrialConnection.identity(mail_inbox!(address: 'owner@shop.example', host: 'imap.shop.example'))
      elsewhere = Growth::TrialConnection.identity(mail_inbox!(login: 'owner@shop.example', host: 'imap.elsewhere.example'))
      # The host is compared without case or surrounding spaces, and the login without case.
      assert_equal own, Growth::TrialConnection.identity(mail_inbox!(login: 'Owner@Shop.example', host: ' IMAP.Shop.Example '))
    end
    assert_equal %w[imap imap], [own[:provider], elsewhere[:provider]]
    refute_equal own[:identity_digest], elsewhere[:identity_digest]
  end

  # (a) A successful sign-in is recorded as a fingerprint, a time and the attempt count only; the other provider_config
  # keys stay.
  def test_a_successful_imap_sign_in_is_recorded_without_the_password_or_the_login
    inbox = mail_inbox!
    inbox.channel.update!(provider_config: { 'other' => 'kept' })
    assert_equal 1, with_imap { assert_equal 'imap', Growth::TrialConnection.identity(inbox)[:provider] }.size
    config = inbox.channel.reload.provider_config
    assert_equal 'kept', config['other']
    assert_equal({ 'verified_at' => NOW.iso8601, 'attempts' => { 'count' => 1, 'first_at' => NOW.iso8601 } },
                 config['toybaco_imap_verified'].except('fingerprint'))
    assert_match(/\A[0-9a-f]{64}\z/, config.dig('toybaco_imap_verified', 'fingerprint'))
    refute_includes config.to_json, IMAP_PASSWORD
    refute_includes config.to_json, inbox.channel.imap_login
  end

  # (b) A wrong password leaves no identity and records the failure; the same settings are not tried again for ten
  # minutes. The log names neither the login nor the password. The success after the ten minutes keeps the failure
  # record and counts the attempt in a new window.
  def test_a_failed_imap_sign_in_has_no_identity_and_is_not_retried_for_ten_minutes
    inbox = mail_inbox!
    log = StringIO.new
    connections = Rails.stub(:logger, ActiveSupport::Logger.new(log)) do
      with_imap(:reject) { assert_nil Growth::TrialConnection.identity(inbox) }
    end
    assert_equal 1, connections.size
    assert_equal NOW.iso8601, imap_record(inbox)['failed_at']
    assert_equal({ 'count' => 1, 'first_at' => NOW.iso8601 }, imap_record(inbox)['attempts'])
    assert_includes log.string, 'Net::IMAP::NoResponseError'
    refute_includes log.string, IMAP_PASSWORD
    refute_includes log.string, inbox.channel.imap_login
    travel_to NOW + 9.minutes
    assert_empty(with_imap { assert_nil Growth::TrialConnection.identity(inbox.reload) })
    travel_to NOW + 11.minutes
    assert_equal 1, with_imap { assert_equal 'imap', Growth::TrialConnection.identity(inbox.reload)[:provider] }.size
    assert_equal %w[attempts failed_at failed_fingerprint fingerprint verified_at], imap_record(inbox).keys.sort
    assert_equal({ 'count' => 1, 'first_at' => (NOW + 11.minutes).iso8601 }, imap_record(inbox)['attempts'])
  end

  # (c) A matching sign-in from the last seven days is reused without connecting; after that Toybaco signs in again.
  def test_a_matching_sign_in_is_reused_for_seven_days
    channel = mail_inbox!.channel
    with_imap { assert Growth::ImapVerification.verified?(channel) }
    travel_to NOW + 6.days
    assert_empty(with_imap { assert Growth::ImapVerification.verified?(channel.reload) })
    travel_to NOW + 7.days + 1.minute
    assert_equal 1, with_imap { assert Growth::ImapVerification.verified?(channel.reload) }.size
  end

  # (d) A changed password, host or login makes another fingerprint, so Toybaco signs in again. Each change comes after
  # the ten minutes of the attempt limit, which counts the successes too.
  def test_a_changed_password_host_or_login_signs_in_again
    channel = mail_inbox!.channel
    with_imap { assert Growth::ImapVerification.verified?(channel) }
    changes = [{ imap_password: 'changed-password' }, { imap_address: 'imap2.example.test' }, { imap_login: 'other@example.test' }]
    changes.each_with_index do |change, index|
      travel_to NOW + ((index + 1) * 11).minutes
      channel.update!(change)
      assert_equal 1, with_imap { assert Growth::ImapVerification.verified?(channel) }.size, change.keys.inspect
      assert_empty(with_imap { assert Growth::ImapVerification.verified?(channel) }, change.keys.inspect)
    end
  end

  # (e) A mailbox signed in another way (xoauth2 and the like) cannot be checked with its password, so it is not covered.
  def test_an_imap_mailbox_signed_in_another_way_is_not_covered
    %w[xoauth2 cram-md5].each do |mechanism|
      inbox = mail_inbox!
      inbox.channel.update!(imap_authentication: mechanism)
      assert_empty(with_imap { refute Growth::ImapVerification.verified?(inbox.channel) }, mechanism)
      assert_empty(with_imap { assert_nil Growth::TrialConnection.identity(inbox) }, mechanism)
    end
  end

  # (f) A connection error or a timeout is a failed sign-in: the page answers normally, the start asks to check the IMAP
  # settings instead of failing, and nothing starts.
  def test_a_connection_error_or_a_timeout_is_a_failed_sign_in_and_not_a_server_error
    imap_example = example_in!(mail_inbox!)
    input = { account_id: @account.id, example_id: imap_example.id, revision: @facts['revision'], confirmed: true }
    Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @owner)) do
      assert_equal 1, with_imap(SocketError) { get '/toybaco/growth/trial', params: { account_id: @account.id } }.size
      assert_response :success
      refute_includes response.body, %(value="#{imap_example.id}")
      travel_to NOW + 11.minutes
      connections = with_imap(Timeout::Error) do
        post '/toybaco/growth/trial', params: input, headers: { 'Origin' => 'http://www.example.com' }, as: :json
      end
      assert_equal 1, connections.size
      assert_response :unprocessable_entity
      assert_equal Growth::TrialStart::MESSAGES.fetch('imap_unverified'), response.parsed_body['error']
    end
    assert_empty Toybaco::GrowthTrial.where(account_id: @account.id)
  end

  # A mailbox that follows the IMAP rule but whose sign-in fails is refused with its own reason, which asks to check the
  # IMAP settings (a Gmail address on another host and a forwarding-only inbox keep the general reason, tested above).
  # The refusal reads the failure just recorded, so the start signs in once.
  def test_a_failed_imap_sign_in_at_the_start_asks_to_check_the_imap_settings
    imap_example = example_in!(mail_inbox!)
    input = { account_id: @account.id, example_id: imap_example.id, revision: @facts['revision'], confirmed: true }
    connections = with_imap(:reject) do
      Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @owner)) do
        post '/toybaco/growth/trial', params: input, headers: { 'Origin' => 'http://www.example.com' }, as: :json
      end
    end
    assert_response :unprocessable_entity
    assert_equal Growth::TrialStart::MESSAGES.fetch('imap_unverified'), response.parsed_body['error']
    assert_operator response.parsed_body['error'].length, :<=, 160
    assert_equal 1, connections.size
    assert_empty Toybaco::GrowthTrial.where(account_id: @account.id)
  end

  # Once the trial runs, its checks for the bot, the reservation and the inbox status (allowed?) read only the sign-in
  # recorded at the start: they never connect, the seven days and a failure record do not apply, and settings that no
  # longer match the record, or no record, stop covering the mailbox.
  def test_the_trial_checks_read_only_the_recorded_sign_in_and_never_connect
    enable_bot_access
    inbox = mail_inbox!
    with_imap { start_with(example_in!(inbox)) }
    channel = inbox.reload.channel
    must_not_connect = ->(*, **) { raise 'the trial checks must not connect to IMAP' }
    Net::IMAP.stub(:new, must_not_connect) do
      travel_to NOW + 8.days
      assert Growth::TrialConnection.allowed?(@account, inbox.reload)
      assert_equal({ 'allowed' => true, 'reason' => 'trial' }, bot_access(inbox))
      assert_equal 'reserved', bot_reserve(inbox)['result']
      record = channel.provider_config['toybaco_imap_verified']
      failed = record.merge('failed_fingerprint' => record['fingerprint'], 'failed_at' => Time.now.utc.iso8601)
      channel.update!(provider_config: channel.provider_config.merge('toybaco_imap_verified' => failed))
      assert Growth::TrialConnection.allowed?(@account, inbox.reload)
      channel.update!(imap_password: 'changed-password')
      refute Growth::TrialConnection.allowed?(@account, inbox.reload)
      channel.update!(imap_password: IMAP_PASSWORD, provider_config: {})
      refute Growth::TrialConnection.allowed?(@account, inbox.reload)
    end
  end

  # A Microsoft API connection as MicrosoftMailbox leaves it (current application and implementation), with the bot assigned.
  def microsoft_inbox!(email)
    config = { 'subject_id' => "subject-#{SecureRandom.hex(4)}", 'application_id' => Toybaco::Connections::Microsoft.client_id,
               'implementation_revision' => Toybaco::Connections::MicrosoftApi::REVISION }
    channel = Channel::Email.create!(account: @account, email: email, provider: 'microsoft', imap_enabled: false,
                                     provider_config: { 'toybaco_microsoft' => config })
    inbox = @account.inboxes.create!(channel: channel, name: email)
    create(:agent_bot_inbox, inbox: inbox, agent_bot: @bot)
    inbox
  end

  # Google Workspace mailboxes sign in on imap.gmail.com too, so a mailbox signed in there over SSL is the same 'gmail'
  # identity as its Gmail API connection, whatever its domain. Without SSL Google's host gives no identity at all.
  def test_a_mailbox_on_google_imap_over_ssl_is_the_api_identity_whatever_its_domain
    workspace = nil
    connections = with_imap { workspace = Growth::TrialConnection.identity(mail_inbox!(login: 'owner@shop.example', host: 'imap.gmail.com')) }
    assert_equal 1, connections.size
    assert_equal 'gmail', workspace[:provider]
    other = create(:account)
    api_inbox = connect(other, email: 'Owner@Shop.example')
    create(:agent_bot_inbox, inbox: api_inbox, agent_bot: create(:agent_bot, account: other))
    assert_equal workspace, Gmail.stub(:allowed?, true) { Growth::TrialConnection.identity(api_inbox) }
    plain = [mail_inbox!(login: 'owner2@shop.example', host: 'imap.gmail.com'), mail_inbox!(address: 'shop.name@gmail.com', host: 'imap.gmail.com')]
    plain.each { |inbox| inbox.channel.update!(imap_enable_ssl: false) }
    assert_empty(with_imap { plain.each { |inbox| assert_nil Growth::TrialConnection.identity(inbox) } })
  end

  # A trial started over the Microsoft API records the Microsoft identity alone. The address of an API connection can be
  # rewritten through the inbox update, so no IMAP identity is made from it (Microsoft 365 over the API and over IMAP stay
  # two identities; see TrialConnection).
  def test_a_trial_started_over_the_microsoft_api_records_only_the_microsoft_identity
    api_example = example_in!(microsoft_inbox!('owner@contoso.example'))
    trial = Toybaco::Connections::Microsoft.stub(:allowed?, true) { start_with(api_example) }
    assert_equal ['microsoft'], trial.identities.pluck(:provider)
  end

  # Sign-in attempts count per inbox whatever the login or the password: after three within ten minutes, Toybaco does not
  # connect for that inbox for ten minutes, so switching the login A -> B -> A or the password cannot keep guessing.
  def test_three_failed_sign_ins_stop_further_attempts_for_the_inbox_whatever_the_login_or_password
    inbox = mail_inbox!
    channel = inbox.channel
    first = channel.imap_login
    attempts = [[first, 'guess-1'], ['other@example.test', 'guess-2'], [first, 'guess-3'], ['other@example.test', 'guess-4'], [first, 'guess-5']]
    connections = with_imap(:reject) do
      attempts.each do |login, password|
        channel.update!(imap_login: login, imap_password: password)
        refute Growth::ImapVerification.verified?(channel)
      end
    end
    assert_equal 3, connections.size
    assert_equal 3, imap_record(inbox).dig('attempts', 'count')
    travel_to NOW + 11.minutes
    assert_equal 1, with_imap(:reject) { refute Growth::ImapVerification.verified?(channel.reload) }.size
  end

  # A failed sign-in at the start stays recorded when the start is refused (Toybaco signs in before the store's lock,
  # outside the start's transaction), so the same settings are not tried again for ten minutes.
  def test_a_failed_sign_in_at_the_start_is_kept_after_the_refusal_rolls_back
    inbox = mail_inbox!
    imap_example = example_in!(inbox)
    with_imap(:reject) { assert_raises(Growth::TrialStart::Unavailable) { start_with(imap_example) } }
    assert_equal 1, imap_record(inbox).dig('attempts', 'count')
    assert_empty(with_imap { assert_raises(Growth::TrialStart::Unavailable) { start_with(imap_example) } })
  end

  # provider_config may be NULL (the column allows it): the sign-in record is written into an empty config, so the failure
  # stays after the refused start and the next start does not connect (the rewrite after a rollback is tested below).
  def test_a_failed_sign_in_on_an_inbox_without_provider_config_is_kept_after_the_refusal_rolls_back
    inbox = mail_inbox!
    imap_example = example_in!(inbox)
    inbox.channel.update_columns(provider_config: nil) # rubocop:disable Rails/SkipsModelValidations
    assert_nil inbox.channel.reload.provider_config
    assert_equal 1, with_imap(:reject) { assert_raises(Growth::TrialStart::Unavailable) { start_with(imap_example) } }.size
    assert_equal ['toybaco_imap_verified'], inbox.channel.reload.provider_config.keys
    assert_equal 1, imap_record(inbox).dig('attempts', 'count')
    assert_empty(with_imap { assert_raises(Growth::TrialStart::Unavailable) { start_with(imap_example) } })
  end

  # A success does not reset the attempt limit: two wrong passwords for the mailbox, then a success on another host with
  # a new fingerprint, and the fourth sign-in to the mailbox does not connect. The success on the other host stays usable
  # without connecting, and after the ten minutes the count starts over.
  def test_a_success_on_another_host_does_not_reset_the_attempt_limit
    channel = mail_inbox!(host: 'imap.target.test').channel
    attempts = [['imap.target.test', 'guess-1', :reject], ['imap.target.test', 'guess-2', :reject], ['imap.own.test', 'own-password', :accept]]
    connections = attempts.flat_map do |host, password, outcome|
      channel.update!(imap_address: host, imap_password: password)
      with_imap(outcome) { assert_equal outcome == :accept, Growth::ImapVerification.verified?(channel) }
    end
    assert_equal ['imap.target.test', 'imap.target.test', 'imap.own.test'], connections.map(&:first)
    channel.update!(imap_address: 'imap.target.test', imap_password: 'guess-3')
    assert_empty(with_imap(:reject) { refute Growth::ImapVerification.verified?(channel) })
    assert_equal({ 'count' => 3, 'first_at' => NOW.iso8601 }, imap_record(channel.inbox)['attempts'])
    channel.update!(imap_address: 'imap.own.test', imap_password: 'own-password')
    assert_empty(with_imap { assert Growth::ImapVerification.verified?(channel) })
    travel_to NOW + 11.minutes
    channel.update!(imap_address: 'imap.target.test', imap_password: 'guess-3')
    assert_equal 1, with_imap(:reject) { refute Growth::ImapVerification.verified?(channel) }.size
    assert_equal({ 'count' => 1, 'first_at' => (NOW + 11.minutes).iso8601 }, imap_record(channel.inbox)['attempts'])
  end

  # A sign-in at a start that is then refused (the identity belongs to another store's trial) still counts and stays
  # recorded, as it is made before the store's lock: the next start does not connect again.
  def test_a_successful_sign_in_at_a_refused_start_stays_recorded_and_counted
    inbox = mail_inbox!
    imap_example = example_in!(inbox)
    trial = nil
    with_imap { trial = start_with(imap_example) }
    trial.update!(account_id: trial.account_id + 1_000_000)
    inbox.channel.update!(imap_password: 'changed-password')
    assert_equal 1, with_imap { assert_raises(Growth::TrialStart::Unavailable) { start_with(imap_example) } }.size
    assert_equal 2, imap_record(inbox).dig('attempts', 'count')
    assert Growth::ImapVerification.recorded?(inbox.channel.reload)
    assert_empty(with_imap { assert_raises(Growth::TrialStart::Unavailable) { start_with(imap_example) } })
  end

  # Toybaco signs in to the IMAP mailbox before it takes the store's lock (Net::IMAP raises inside the lock here), and the
  # lock builds the identities from the sign-in recorded just before: a success starts the trial. A second start of the
  # started store returns the trial before any sign-in, even when the settings changed meanwhile.
  def test_the_start_signs_in_before_the_store_lock_and_starts
    inbox = mail_inbox!
    imap_example = example_in!(inbox)
    trial = nil
    assert_equal 1, with_imap_outside_the_store_lock { trial = start_with(imap_example) }.size
    assert_equal ['imap'], trial.identities.pluck(:provider)
    inbox.channel.update!(imap_password: 'changed-password')
    assert_empty(with_imap_outside_the_store_lock { assert_equal trial, start_with(imap_example) })
  end

  # Only a user who may start the trial makes Toybaco sign in: the start checks the user and the store before it connects,
  # so a member's attempt uses none of the mailbox's sign-in attempts.
  def test_a_start_refused_for_the_user_does_not_sign_in
    imap_example = example_in!(mail_inbox!)
    member = create(:user, account: @account)
    connections = with_imap do
      error = assert_raises(Growth::TrialStart::Unavailable) do
        Growth::TrialStart.new(@account, member).start!(example_id: imap_example.id, revision: @facts['revision'], confirmed: true)
      end
      assert_equal Growth::TrialStart::MESSAGES.fetch('not_owner'), error.message
    end
    assert_empty connections
  end

  # A failed sign-in before the store's lock refuses the start with the IMAP reason, and nothing connects in the lock.
  def test_a_failed_sign_in_before_the_store_lock_refuses_with_the_imap_reason
    imap_example = example_in!(mail_inbox!)
    error = nil
    connections = with_imap_outside_the_store_lock(:reject) do
      error = assert_raises(Growth::TrialStart::Unavailable) { start_with(imap_example) }
    end
    assert_equal 1, connections.size
    assert_equal Growth::TrialStart::MESSAGES.fetch('imap_unverified'), error.message
    assert_empty Toybaco::GrowthTrial.where(account_id: @account.id)
  end

  # A sign-in that the server accepted stands when the logout after it fails (the connection closed there, or the time ran
  # out): the trial starts, and the record keeps the success alone (no failure) with one attempt counted. The log names
  # the failure's class only, not the login, the host or the password.
  def assert_a_failed_logout_after_the_sign_in_starts_the_trial(error)
    inbox = mail_inbox!
    imap_example = example_in!(inbox)
    log = StringIO.new
    trial = nil
    connections = Rails.stub(:logger, ActiveSupport::Logger.new(log)) do
      with_imap_outside_the_store_lock(logout: error) { trial = start_with(imap_example) }
    end
    assert_equal 1, connections.size
    assert_equal ['imap'], trial.identities.pluck(:provider)
    record = imap_record(inbox)
    assert_equal %w[attempts fingerprint verified_at], record.keys.sort
    assert_equal Growth::ImapVerification.fingerprint(Growth::ImapVerification.snapshot(inbox.channel)), record['fingerprint']
    assert_equal NOW.iso8601, record['verified_at']
    assert_nil record['failed_fingerprint']
    assert_equal 1, record.dig('attempts', 'count')
    assert_includes log.string, "channel=#{inbox.channel_id} logout failed after sign-in: #{error.name}"
    [IMAP_PASSWORD, inbox.channel.imap_login, 'imap.example.test'].each { |value| refute_includes log.string, value }
  end

  def test_a_connection_closed_at_the_logout_after_the_sign_in_still_starts_the_trial
    assert_a_failed_logout_after_the_sign_in_starts_the_trial(EOFError)
  end

  def test_a_timeout_at_the_logout_after_the_sign_in_still_starts_the_trial
    assert_a_failed_logout_after_the_sign_in_starts_the_trial(Timeout::Error)
  end

  # A mailbox whose bot is not active, or which Chatwoot asks to reauthorize, is left out before any sign-in, and so is the
  # refusal for it: the start names the inbox and the bot (example_inbox), not the IMAP settings, never opens a connection
  # and leaves no sign-in record.
  def test_a_mailbox_with_an_inactive_bot_or_asked_to_reauthorize_is_refused_without_signing_in
    inbox = mail_inbox!
    imap_example = example_in!(inbox)
    must_not_connect = ->(*, **) { raise 'the start must not connect to IMAP for a mailbox left out before the sign-in' }
    refusal = lambda do
      Net::IMAP.stub(:new, must_not_connect) { assert_raises(Growth::TrialStart::Unavailable) { start_with(imap_example) } }.message
    end
    inbox.agent_bot_inbox.update!(status: :inactive)
    assert_equal Growth::TrialStart::MESSAGES.fetch('example_inbox'), refusal.call
    inbox.agent_bot_inbox.update!(status: :active)
    inbox.channel.prompt_reauthorization!
    assert_predicate inbox.channel, :reauthorization_required?
    assert_equal Growth::TrialStart::MESSAGES.fetch('example_inbox'), refusal.call
    assert_nil imap_record(inbox)
    assert_empty Toybaco::GrowthTrial.where(account_id: @account.id)
  ensure
    inbox&.channel&.reauthorized!
  end

  # Starts from an answer example in the inbox while every sign-in answers NO (on_connect runs as Net::IMAP.new is called)
  # and returns the refusal, the connections made and the attempts counted for the inbox.
  def refused_imap_start(inbox, on_connect: nil)
    imap_example = example_in!(inbox)
    error = nil
    connections = with_imap_outside_the_store_lock(:reject, on_connect: on_connect) do
      error = assert_raises(Growth::TrialStart::Unavailable) { start_with(imap_example) }
    end
    [error.message, connections.size, imap_record(inbox).dig('attempts', 'count')]
  end

  # A failed sign-in at the start is refused with the IMAP reason after that one sign-in: the refusal reads the record the
  # sign-in left and does not connect again, also when the settings changed during the sign-in (the failure is recorded
  # for the settings tried, so a check of the new settings would connect once more).
  def test_a_failed_sign_in_at_the_start_is_refused_without_signing_in_again
    refused = [Growth::TrialStart::MESSAGES.fetch('imap_unverified'), 1, 1]
    assert_equal refused, refused_imap_start(mail_inbox!)
    inbox = mail_inbox!
    change = -> { Channel::Email.find(inbox.channel_id).update!(imap_password: 'changed-password') }
    assert_equal refused, refused_imap_start(inbox, on_connect: change)
  end

  # A start while the inbox is at its sign-in limit (three attempts within ten minutes) does not connect, and the refusal
  # asks to check the IMAP settings without connecting either.
  def test_a_start_at_the_sign_in_limit_is_refused_with_the_imap_reason_without_connecting
    inbox = mail_inbox!
    imap_example = example_in!(inbox)
    channel = inbox.channel
    connections = with_imap(:reject) do
      %w[guess-1 guess-2 guess-3].each do |password|
        channel.update!(imap_password: password)
        refute Growth::ImapVerification.verified?(channel)
      end
    end
    assert_equal 3, connections.size
    channel.update!(imap_password: IMAP_PASSWORD)
    error = nil
    assert_empty(with_imap_outside_the_store_lock { error = assert_raises(Growth::TrialStart::Unavailable) { start_with(imap_example) } })
    assert_equal Growth::TrialStart::MESSAGES.fetch('imap_unverified'), error.message
    assert_equal 3, imap_record(inbox).dig('attempts', 'count')
  end

  # Writes a success for the inbox's current settings that is older than the seven days (verified_at eight days back): the
  # record still matches the settings (recorded?), but holds no success within the seven days (fresh?).
  def record_old_success!(channel, attempts: nil)
    record = { 'fingerprint' => Growth::ImapVerification.fingerprint(Growth::ImapVerification.snapshot(channel)),
               'verified_at' => (NOW - 8.days).iso8601 }
    record['attempts'] = attempts if attempts
    channel.update_columns(provider_config: { 'toybaco_imap_verified' => record }) # rubocop:disable Rails/SkipsModelValidations
  end

  # An old success for the same settings does not hide a failed sign-in at the start: the refusal asks to check the IMAP
  # settings after that one sign-in, as no success within the seven days is recorded.
  def test_a_failed_sign_in_after_an_old_success_for_the_same_settings_is_refused_with_the_imap_reason
    inbox = mail_inbox!
    record_old_success!(inbox.channel)
    assert_equal [Growth::TrialStart::MESSAGES.fetch('imap_unverified'), 1, 1], refused_imap_start(inbox)
    record = imap_record(inbox)
    assert_equal [record['fingerprint'], NOW.iso8601], record.values_at('failed_fingerprint', 'failed_at')
    assert Growth::ImapVerification.recorded?(inbox.channel)
    refute Growth::ImapVerification.fresh?(inbox.channel)
  end

  # Nor does it hide the sign-in limit: a start while the inbox is at its limit does not connect, and the refusal asks to
  # check the IMAP settings.
  def test_a_start_at_the_sign_in_limit_after_an_old_success_for_the_same_settings_is_refused_with_the_imap_reason
    inbox = mail_inbox!
    imap_example = example_in!(inbox)
    record_old_success!(inbox.channel, attempts: { 'count' => 3, 'first_at' => NOW.iso8601 })
    error = nil
    assert_empty(with_imap_outside_the_store_lock { error = assert_raises(Growth::TrialStart::Unavailable) { start_with(imap_example) } })
    assert_equal Growth::TrialStart::MESSAGES.fetch('imap_unverified'), error.message
    assert_equal 3, imap_record(inbox).dig('attempts', 'count')
    assert Growth::ImapVerification.recorded?(inbox.channel)
  end

  # Settings changed after the sign-in and before the store's lock do not make the lock connect: the record no longer
  # matches the settings, so the mailbox is left out (here the only one, so the start asks to connect a mailbox).
  def test_settings_changed_before_the_store_lock_leave_the_mailbox_out_without_connecting
    inbox = mail_inbox!
    imap_example = example_in!(inbox)
    change = -> { Channel::Email.find(inbox.channel_id).update!(imap_password: 'changed-password') }
    error = nil
    connections = with_imap_outside_the_store_lock(on_lock: change) do
      error = assert_raises(Growth::TrialStart::Unavailable) { start_with(imap_example) }
    end
    assert_equal 1, connections.size
    assert_equal Growth::TrialStart::MESSAGES.fetch('no_mail_inbox'), error.message
  end

  # Another mailbox whose only success is older than seven days and whose fresh sign-in before the store's lock fails is
  # left out of the trial, although that old record still matches its settings: the lock keeps only what the sign-ins
  # just before it confirmed.
  def test_a_mailbox_with_only_an_old_success_is_left_out_after_a_failed_fresh_sign_in
    stale = mail_inbox!
    with_imap { assert Growth::ImapVerification.verified?(stale.channel) }
    travel_to NOW + 8.days
    fresh = mail_inbox!
    imap_example = example_in!(fresh)
    trial = nil
    connections = with_imap_outside_the_store_lock(accepted: fresh.channel.imap_login) { trial = start_with(imap_example) }
    assert_equal 2, connections.size
    assert Growth::ImapVerification.recorded?(stale.channel.reload)
    assert_equal [Growth::TrialConnection.recorded_identity(fresh.reload)[:identity_digest]], trial.identities.pluck(:identity_digest)
  end

  # A trailing dot or a Unicode space around the address's domain makes no other address, as the host ignores its
  # trailing dot: 'shop.name@gmail.com.' signed in on Google's IMAP is the Gmail API identity of shop.name@gmail.com, and on
  # another host it is still a Gmail address, which is not a trial connection.
  def test_a_trailing_dot_or_a_unicode_space_on_the_address_domain_is_the_same_address
    values = ["Shop.Name@Gmail.com.　", " shop@example.test. ", '+tag@gmail.com']
    assert_equal ['shopname@gmail.com', 'shop@example.test', nil], values.map { |value| Growth::TrialConnection.normalized_email(value) }
    imap = nil
    with_imap do
      imap = Growth::TrialConnection.identity(mail_inbox!(address: 'shop.name@gmail.com.', login: "shop.name@gmail.com. ", host: 'imap.gmail.com'))
    end
    other = create(:account)
    api_inbox = connect(other, email: 'shop.name@gmail.com')
    create(:agent_bot_inbox, inbox: api_inbox, agent_bot: create(:agent_bot, account: other))
    assert_equal imap, Gmail.stub(:allowed?, true) { Growth::TrialConnection.identity(api_inbox) }
    assert_nil Growth::TrialConnection.imap_identity(mail_inbox!(address: 'other.name@gmail.com.', host: 'imap.example.test').channel)
  end

  # The attempt count never goes down within its window, nor does the window's start move back: a window that another
  # server's clock began slightly later counts on (the rewrite after a rollback included), and a full count there stops
  # the next sign-in.
  def test_the_attempt_count_goes_on_from_a_window_that_began_slightly_later
    channel = mail_inbox!.channel
    later = (NOW + 30).iso8601
    record = { 'attempts' => { 'count' => 1, 'first_at' => later } }
    channel.update_columns(provider_config: { 'toybaco_imap_verified' => record }) # rubocop:disable Rails/SkipsModelValidations
    assert_equal 1, with_imap(:reject) { refute Growth::ImapVerification.verified?(channel) }.size
    assert_equal({ 'count' => 2, 'first_at' => later }, imap_record(channel.inbox)['attempts'])
    tried = Growth::ImapVerification.fingerprint(Growth::ImapVerification.snapshot(channel))
    Growth::ImapVerification.rewrite!(channel.id, :failed, tried)
    assert_equal({ 'count' => 3, 'first_at' => later }, imap_record(channel.inbox)['attempts'])
    channel.update!(imap_password: 'changed-password')
    assert_empty(with_imap { refute Growth::ImapVerification.verified?(channel) })
  end

  # A window recorded to begin more than ten minutes ahead is not trusted (a broken clock or record must not hold the
  # mailbox back): the sign-in goes ahead and the count starts over from now.
  def test_an_attempt_window_far_ahead_is_not_trusted
    channel = mail_inbox!.channel
    record = { 'attempts' => { 'count' => 3, 'first_at' => (NOW + 20.minutes).iso8601 } }
    channel.update_columns(provider_config: { 'toybaco_imap_verified' => record }) # rubocop:disable Rails/SkipsModelValidations
    assert_equal 1, with_imap(:reject) { refute Growth::ImapVerification.verified?(channel) }.size
    assert_equal({ 'count' => 1, 'first_at' => NOW.iso8601 }, imap_record(channel.inbox)['attempts'])
  end

  # A sign-in made inside a transaction that then rolls back stays recorded and counted (TrialStart signs in outside its
  # transaction, but another caller may not): the rewrite after the rollback adds the same record to the latest value, an
  # inbox whose provider_config is NULL included.
  def test_sign_ins_inside_a_rolled_back_transaction_stay_recorded_and_counted
    channel = mail_inbox!.channel
    channel.update_columns(provider_config: nil) # rubocop:disable Rails/SkipsModelValidations
    with_imap(:reject) do
      ActiveRecord::Base.transaction(requires_new: true) do
        refute Growth::ImapVerification.verified?(channel)
        raise ActiveRecord::Rollback
      end
    end
    assert_equal ['toybaco_imap_verified'], channel.reload.provider_config.keys
    assert_equal 1, imap_record(channel.inbox).dig('attempts', 'count')
    assert imap_record(channel.inbox)['failed_fingerprint']
    channel.update!(imap_password: 'changed-password')
    with_imap do
      ActiveRecord::Base.transaction(requires_new: true) do
        assert Growth::ImapVerification.verified?(channel)
        raise ActiveRecord::Rollback
      end
    end
    assert_equal 2, imap_record(channel.inbox).dig('attempts', 'count')
    assert Growth::ImapVerification.recorded?(channel.reload)
  end

  # The rewrite after a rollback adds the success or the failure only while the inbox still has the settings that were
  # tried: after a change it counts the attempt alone, so the record of the new settings stays.
  def test_the_rewrite_adds_the_result_only_for_the_settings_still_saved
    channel = mail_inbox!.channel
    tried = Growth::ImapVerification.fingerprint(Growth::ImapVerification.snapshot(channel))
    channel.update!(imap_password: 'changed-password')
    with_imap { assert Growth::ImapVerification.verified?(channel) }
    current = imap_record(channel.inbox)['fingerprint']
    Growth::ImapVerification.rewrite!(channel.id, :succeeded, tried)
    Growth::ImapVerification.rewrite!(channel.id, :failed, tried)
    record = imap_record(channel.inbox)
    assert_equal [current, nil, 3], [record['fingerprint'], record['failed_fingerprint'], record.dig('attempts', 'count')]
  end

  # A trailing dot does not make another host: 'mail.example.test.' is 'mail.example.test' for the identity and the record.
  def test_a_trailing_dot_on_the_host_is_the_same_host
    inbox = mail_inbox!(host: 'mail.example.test')
    identity = nil
    with_imap { identity = Growth::TrialConnection.identity(inbox) }
    inbox.channel.update!(imap_address: 'mail.example.test.')
    assert_empty(with_imap { assert_equal identity, Growth::TrialConnection.identity(inbox.reload) })
  end

  # Toybaco signs in with the settings it read. If another connection rewrites the login and the host meanwhile (to
  # someone's Gmail), that sign-in proves nothing about the new settings: no success is recorded, there is no identity,
  # and no trial starts.
  def test_settings_rewritten_during_the_sign_in_get_no_identity_and_no_trial
    inbox = mail_inbox!
    original = inbox.channel.imap_login
    rewrite = lambda do |_host, **_options|
      Channel::Email.find(inbox.channel_id).update!(imap_login: 'victim@gmail.com', imap_address: 'imap.gmail.com')
      FakeImap.new(false, nil, original)
    end
    Net::IMAP.stub(:new, rewrite) { assert_nil Growth::TrialConnection.identity(inbox) }
    assert_equal({ 'attempts' => { 'count' => 1, 'first_at' => NOW.iso8601 } }, imap_record(inbox))
    inbox.channel.reload.update!(imap_login: original, imap_address: 'imap.example.test')
    imap_example = example_in!(inbox)
    Net::IMAP.stub(:new, rewrite) { assert_raises(Growth::TrialStart::Unavailable) { start_with(imap_example) } }
    assert_empty Toybaco::GrowthTrial.where(account_id: @account.id)
    assert_empty Toybaco::GrowthTrialIdentity.where(provider: 'gmail')
  end

  # A store that changes the IMAP password during the trial gets the mailbox back by opening the trial screen: the screen
  # signs in once with the new settings and records them, and the trial's checks cover the mailbox again.
  def test_opening_the_trial_screen_signs_in_again_after_a_password_change
    inbox = mail_inbox!
    with_imap { start_with(example_in!(inbox)) }
    inbox.channel.update!(imap_password: 'changed-password')
    refute Growth::TrialConnection.allowed?(@account, inbox.reload)
    connections = with_imap do
      Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @owner)) { get '/toybaco/growth/trial', params: { account_id: @account.id } }
    end
    assert_response :success
    assert_equal 1, connections.size
    assert_includes response.body, '受信箱のパスワードを変えたときは、この画面を開き直すと接続を確かめ直します。'
    assert Growth::TrialConnection.allowed?(@account, inbox.reload)
    # With the record matching again, reading the trial state does not connect, even after the seven days that a sign-in
    # counts for at the start.
    travel_to NOW + 8.days
    assert_empty(with_imap { Growth::TrialState.new(@account).read })
  end

  # The guide counts mail inboxes by the trial's identity rule (OnboardingInboxes#visible): an IMAP mailbox counts, a
  # Gmail address only on Google's IMAP, a forwarding-only inbox not at all, and the Gmail connection follows its release.
  # The guide does not sign in to the mailboxes.
  def test_the_guide_counts_an_imap_mailbox_but_not_a_forwarding_only_one
    imap = mail_inbox!
    mail_inbox!(imap_enabled: false)
    mail_inbox!(address: 'shop.name@gmail.com', host: 'imap.example.test')
    google = mail_inbox!(address: 'shop.name+guide@gmail.com', host: 'imap.gmail.com')
    guide = Growth::OnboardingInboxes.new(@account, @owner, administrator: true)
    connections = with_imap do
      assert_equal [imap, google], guide.visible
      assert guide.any_in_store?
      Gmail.stub(:allowed?, true) { assert_equal [@inbox, imap, google], guide.visible }
    end
    assert_empty connections
  end

  # The guide's inbox list (OnboardingInboxes#describe, read into the onboarding JSON) names a standard mail inbox 'email'
  # with its address as the label, over IMAP or forwarding-only; the Gmail and Microsoft API connections keep their names.
  def test_the_guide_describes_a_standard_mail_inbox_as_email_and_the_api_connections_by_name
    guide = Growth::OnboardingInboxes.new(@account, @owner, administrator: true)
    imap = mail_inbox!
    address = imap.channel.email
    assert_equal({ 'provider' => 'email', 'label' => address, 'email' => address }, guide.describe(imap).slice('provider', 'label', 'email'))
    assert_equal 'email', guide.describe(mail_inbox!(imap_enabled: false))['provider']
    assert_equal 'gmail', guide.describe(@inbox)['provider']
    channel = Channel::Email.create!(account: @account, email: "ms-#{SecureRandom.hex(4)}@example.test", provider: 'microsoft',
                                     provider_config: { 'toybaco_microsoft' => { 'subject_id' => 'fixture-subject' } })
    assert_equal 'microsoft', guide.describe(@account.inboxes.create!(channel: channel, name: channel.email))['provider']
    # The onboarding JSON lists the IMAP inbox the same way (the Gmail connection still waits for its review).
    assert_includes Growth::Onboarding.new(@account, @owner).read['inboxes'].map { |entry| entry.slice('id', 'provider', 'label') },
                    { 'id' => imap.id, 'provider' => 'email', 'label' => address }
  end

  # Chatwoot's reply mailer needs an SMTP address, and the test image would otherwise deliver with sendmail. The block
  # delivers into ActionMailer's test deliveries instead.
  def with_test_mail_delivery
    previous = [ActionMailer::Base.delivery_method, ENV.fetch('SMTP_ADDRESS', nil)]
    ActionMailer::Base.delivery_method = :test
    ENV['SMTP_ADDRESS'] = 'smtp.example.test'
    yield
  ensure
    ActionMailer::Base.delivery_method = previous.first
    ENV['SMTP_ADDRESS'] = previous.last
  end

  # The guide's reply step counts a reply from an IMAP mailbox once Chatwoot's sender sent it: Email::SendOnEmailService
  # keeps the sent mail's Message-ID as source_id, and a send that failed is marked failed and does not count.
  def test_the_guide_counts_a_reply_sent_from_an_imap_mailbox
    inbox = mail_inbox!
    conversation = create(:conversation, account: @account, inbox: inbox, status: :open)
    create(:message, account: @account, inbox: inbox, conversation: conversation, message_type: :incoming, private: false,
                     content: '予約できますか？', source_id: "guide-#{SecureRandom.hex(4)}@example.test")
    guide = Growth::Onboarding.new(@account, @owner)
    guide.update!('purpose' => 'inbox')
    assert_equal 'reply', guide.read['phase']
    reply = lambda do
      create(:message, account: @account, inbox: inbox, conversation: conversation, message_type: :outgoing, private: false,
                       sender: @owner, content: 'はい、できます。')
    end
    reply.call.update!(source_id: "failed-#{SecureRandom.hex(4)}@example.test", status: :failed)
    assert_equal 'reply', guide.read['phase']
    sent = reply.call
    with_test_mail_delivery { Email::SendOnEmailService.new(message: sent).perform }
    assert_predicate sent.reload.source_id, :present?
    # The counted reply moves the guide past its reply step to the decide step (how the inbox's AI reply is used, #432).
    assert_equal %w[decide], guide.read.values_at('phase')
    assert_equal true, guide.read['replied']
  end
end

# Toybaco's sign-in check across separate PostgreSQL sessions (no test transaction): the row lock serializes concurrent
# checks of one inbox, and the rewrite after a rolled-back start merges into the latest saved value.
class ToybacoGrowthImapVerificationLockRuntimeTest < ActiveSupport::TestCase
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = false
  Verification = Toybaco::Growth::ImapVerification

  def setup
    @account = create(:account)
    address = "lock-#{SecureRandom.hex(6)}@example.test"
    @channel = Channel::Email.create!(account: @account, email: address, imap_enabled: true, imap_login: address,
                                      imap_password: 'imap-fixture-password', imap_address: 'imap.example.test', imap_port: 993)
  end

  def teardown
    @inbox&.destroy!
    Channel::Email.find_by(id: @channel.id)&.destroy! if @channel
    @account&.destroy!
  end

  # Waits until another session of this database waits for a lock, so that a holder lets go only after the other waits.
  # The test runs inside the Rails executor, so the polling query bypasses the query cache.
  def wait_for_lock_waiter
    sql = "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
    Timeout.timeout(10) do
      sleep 0.05 until ActiveRecord::Base.uncached { ActiveRecord::Base.connection.select_value(sql) }.to_i.positive?
    end
  end

  def in_session(&)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&) }
  end

  # Two sessions check the same inbox at once, with two attempts counted (one short of the limit). The first signs in
  # (and fails) holding the row lock while the second waits; the second then reads the recorded attempt and does not
  # connect: one sign-in in all.
  def test_concurrent_checks_of_one_inbox_do_not_pass_the_failure_limit_together
    attempts = { 'count' => 2, 'first_at' => Time.now.utc.iso8601 }
    @channel.update!(provider_config: { Verification::KEY => { 'attempts' => attempts } })
    connections = Queue.new
    signing_in = Queue.new
    release = Queue.new
    opener = lambda do |host, **_options|
      connections << host
      signing_in << true
      release.pop
      ToybacoGrowthTrialRuntimeTest::FakeImap.new(true)
    end
    results = Queue.new
    sessions = []
    Net::IMAP.stub(:new, opener) do
      sessions << in_session { results << Verification.verified?(Channel::Email.find(@channel.id)) }
      Timeout.timeout(10) { signing_in.pop }
      sessions << in_session { results << Verification.verified?(Channel::Email.find(@channel.id)) }
      wait_for_lock_waiter
    ensure
      # Let the signing-in session go even when a wait above failed, so no session keeps the row lock.
      2.times { release << true }
      sessions.each { |thread| thread.join(15) || thread.kill }
    end
    assert_equal 2, results.size, 'both verification sessions finished'
    assert_equal 1, connections.size
    assert_equal [false, false], [results.pop, results.pop]
    assert_equal 3, @channel.reload.provider_config.dig(Verification::KEY, 'attempts', 'count')
  end

  # A check that waited for the row lock reads the settings again: when another session changed the login meanwhile, it
  # does not sign in with the settings it read before (no connection, no record).
  def test_a_check_that_waited_for_the_lock_does_not_sign_in_with_settings_changed_meanwhile
    locked = Queue.new
    release = Queue.new
    connections = Queue.new
    results = Queue.new
    opener = lambda do |host, **_options|
      connections << host
      ToybacoGrowthTrialRuntimeTest::FakeImap.new(false)
    end
    sessions = []
    Net::IMAP.stub(:new, opener) do
      sessions << in_session do
        Channel::Email.transaction do
          row = Channel::Email.lock.find(@channel.id)
          locked << true
          release.pop
          row.update_columns(imap_login: "changed-#{SecureRandom.hex(4)}@example.test") # rubocop:disable Rails/SkipsModelValidations
        end
      end
      Timeout.timeout(10) { locked.pop }
      sessions << in_session { results << Verification.verified?(Channel::Email.find(@channel.id)) }
      wait_for_lock_waiter
    ensure
      release << true
      sessions.each { |thread| thread.join(15) || thread.kill }
    end
    assert_equal [false], [results.pop]
    assert_equal 0, connections.size
    assert_nil @channel.reload.provider_config.dig(Verification::KEY)
  end

  # The rewrite after a rollback takes the row lock and merges the attempt and the failure into the latest value: a
  # success record and an unrelated key that another session saved meanwhile stay, the attempts counted meanwhile (in a
  # window that began after the rewrite was called) go on, and the failure takes the time read after the lock.
  def test_the_rewrite_after_a_rollback_keeps_values_saved_meanwhile
    locked = Queue.new
    release = Queue.new
    tried = Verification.fingerprint(Verification.snapshot(@channel))
    written = Queue.new
    sessions = []
    begin
      sessions << in_session do
        Channel::Email.transaction do
          row = Channel::Email.lock.find(@channel.id)
          locked << true
          release.pop
          sleep 1.1 # the records keep whole seconds: the window below begins after the rewrite was called
          now = Time.now.utc.iso8601
          written << now
          record = { 'fingerprint' => 'saved', 'verified_at' => now, 'attempts' => { 'count' => 2, 'first_at' => now } }
          row.update_columns(provider_config: { 'other' => 'kept', Verification::KEY => record }) # rubocop:disable Rails/SkipsModelValidations
        end
      end
      Timeout.timeout(10) { locked.pop }
      sessions << in_session { Verification.rewrite!(@channel.id, :failed, tried) }
      wait_for_lock_waiter
    ensure
      release << true
      sessions.each { |thread| thread.join(15) || thread.kill }
    end
    config = @channel.reload.provider_config
    assert_equal 'kept', config['other']
    assert_equal ['saved', tried], config[Verification::KEY].values_at('fingerprint', 'failed_fingerprint')
    assert_equal 3, config.dig(Verification::KEY, 'attempts', 'count')
    assert_operator config.dig(Verification::KEY, 'failed_at'), :>=, written.pop
  end

  # A check that waited for the row lock reads the time after taking it, so a success that another session recorded
  # meanwhile (after this check was called) is fresh for it: it does not connect again.
  def test_a_check_that_waited_for_the_lock_uses_the_success_recorded_meanwhile
    locked = Queue.new
    release = Queue.new
    connections = Queue.new
    results = Queue.new
    fingerprint = Verification.fingerprint(Verification.snapshot(@channel))
    opener = lambda do |host, **_options|
      connections << host
      ToybacoGrowthTrialRuntimeTest::FakeImap.new(false)
    end
    sessions = []
    Net::IMAP.stub(:new, opener) do
      sessions << in_session do
        Channel::Email.transaction do
          row = Channel::Email.lock.find(@channel.id)
          locked << true
          release.pop
          sleep 1.1 # the records keep whole seconds: the success below comes after the check was called
          record = { 'fingerprint' => fingerprint, 'verified_at' => Time.now.utc.iso8601 }
          row.update_columns(provider_config: { Verification::KEY => record }) # rubocop:disable Rails/SkipsModelValidations
        end
      end
      Timeout.timeout(10) { locked.pop }
      sessions << in_session { results << Verification.verified?(Channel::Email.find(@channel.id)) }
      wait_for_lock_waiter
    ensure
      release << true
      sessions.each { |thread| thread.join(15) || thread.kill }
    end
    assert_equal [true], [results.pop]
    assert_equal 0, connections.size
  end

  # A check inside a transaction that rolls back is written again after the rollback onto the latest value: when another
  # session counts attempts while the rewrite waits for the row, the count goes on from that value and does not drop.
  def test_the_rewrite_after_a_rollback_goes_on_from_the_attempts_counted_meanwhile
    signing_in = Queue.new
    release = Queue.new
    opener = lambda do |_host, **_options|
      signing_in << true
      release.pop
      ToybacoGrowthTrialRuntimeTest::FakeImap.new(true)
    end
    sessions = []
    Net::IMAP.stub(:new, opener) do
      sessions << in_session do
        ActiveRecord::Base.transaction do
          Verification.verified?(Channel::Email.find(@channel.id))
          raise ActiveRecord::Rollback
        end
      end
      Timeout.timeout(10) { signing_in.pop }
      sessions << in_session do
        Channel::Email.transaction do
          row = Channel::Email.lock.find(@channel.id)
          sleep 1.1 # the records keep whole seconds: this window begins after the rolled-back check
          attempts = { 'count' => 2, 'first_at' => Time.now.utc.iso8601 }
          row.update_columns(provider_config: { Verification::KEY => { 'attempts' => attempts } }) # rubocop:disable Rails/SkipsModelValidations
        end
      end
      wait_for_lock_waiter
    ensure
      release << true
      sessions.each { |thread| thread.join(15) || thread.kill }
    end
    record = @channel.reload.provider_config[Verification::KEY]
    assert_equal 3, record.dig('attempts', 'count')
    assert_equal Verification.fingerprint(Verification.snapshot(@channel)), record['failed_fingerprint']
  end

  # A check that waited for the row lock reads the attempts that another session counted meanwhile: a full count, in a
  # window that began after the check was called, stops it from connecting.
  def test_a_check_that_waited_for_the_lock_reads_the_attempts_counted_meanwhile
    locked = Queue.new
    release = Queue.new
    connections = Queue.new
    results = Queue.new
    opener = lambda do |host, **_options|
      connections << host
      ToybacoGrowthTrialRuntimeTest::FakeImap.new(false)
    end
    sessions = []
    Net::IMAP.stub(:new, opener) do
      sessions << in_session do
        Channel::Email.transaction do
          row = Channel::Email.lock.find(@channel.id)
          locked << true
          release.pop
          sleep 1.1 # the records keep whole seconds: the window below begins after the check was called
          attempts = { 'count' => 3, 'first_at' => Time.now.utc.iso8601 }
          row.update_columns(provider_config: { Verification::KEY => { 'attempts' => attempts } }) # rubocop:disable Rails/SkipsModelValidations
        end
      end
      Timeout.timeout(10) { locked.pop }
      sessions << in_session { results << Verification.verified?(Channel::Email.find(@channel.id)) }
      wait_for_lock_waiter
    ensure
      release << true
      sessions.each { |thread| thread.join(15) || thread.kill }
    end
    assert_equal [false], [results.pop]
    assert_equal 0, connections.size
  end

  # Signs in once with the IMAP stub waiting inside, and meanwhile saves the inbox's name and its channel's SMTP address in
  # another session, in the order of the inbox update API (the Inbox, then the Channel, in one transaction). Returns the
  # results of both sessions and the errors they raised.
  def save_the_inbox_during_a_sign_in(rejected:, name:, smtp:)
    signing_in = Queue.new
    release = Queue.new
    results = Queue.new
    errors = Queue.new
    opener = lambda do |_host, **_options|
      signing_in << true
      release.pop
      ToybacoGrowthTrialRuntimeTest::FakeImap.new(rejected)
    end
    sessions = []
    Net::IMAP.stub(:new, opener) do
      sessions << in_session { collect_result(results, errors) { Verification.verified?(Channel::Email.find(@channel.id)) } }
      Timeout.timeout(10) { signing_in.pop }
      sessions << in_session { collect_result(results, errors) { save_inbox_and_channel(name, smtp) } }
      wait_for_lock_waiter
    ensure
      release << true
      sessions.each { |thread| thread.join(15) || thread.kill }
    end
    [Array.new(results.size) { results.pop }, Array.new(errors.size) { errors.pop }]
  end

  def save_inbox_and_channel(name, smtp)
    ActiveRecord::Base.transaction do
      inbox = Inbox.find(@inbox.id)
      inbox.update!(name: name)
      inbox.channel.update!(smtp_address: smtp)
    end
    :saved
  end

  def collect_result(results, errors)
    results << yield
  rescue StandardError => e
    errors << e
  end

  # The check holds the inbox's row lock while it signs in and writes its record without touching the Inbox, so a save in
  # the order of the inbox update API (the Inbox, then the Channel) cannot deadlock with it: the save waits for the check
  # and completes, after a success and after a failure, and the check's record stays.
  def test_saving_the_inbox_and_its_channel_during_a_sign_in_completes_without_a_deadlock
    @inbox = @account.inboxes.create!(channel: @channel, name: 'Lock inbox')
    results, errors = save_the_inbox_during_a_sign_in(rejected: false, name: 'Renamed lock inbox', smtp: 'smtp1.example.test')
    assert_empty errors.map(&:class)
    assert_equal [:saved, true], results.sort_by(&:inspect)
    assert Verification.recorded?(@channel.reload)
    @channel.update!(imap_password: 'changed-password')
    results, errors = save_the_inbox_during_a_sign_in(rejected: true, name: 'Renamed again', smtp: 'smtp2.example.test')
    assert_empty errors.map(&:class)
    assert_equal [:saved, false], results.sort_by(&:inspect)
    failed = @channel.reload.provider_config.dig(Verification::KEY, 'failed_fingerprint')
    assert_equal Verification.fingerprint(Verification.snapshot(@channel)), failed
    assert_equal ['Renamed again', 'smtp2.example.test'], [@inbox.reload.name, @channel.smtp_address]
  end
end
