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
    terms = Toybaco::PlanCatalog.default.definition('free', '2026-09-25.1')
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

  # 「あとで設定する」は、先へ進めた段の一覧を丸ごと保存する(一覧から外せばその段へ戻る)。
  def skip(*steps)
    update_preference({ skipped: steps })
    assert_response :success
    response.parsed_body
  end

  def save_facts(fields = { name: 'テスト店舗', hours: '10時から19時' })
    put '/toybaco/growth/facts', params: { account_id: @account.id, confirmed: true, fields: fields },
                                 headers: { 'Origin' => 'http://www.example.com' }, as: :json
    assert_response :success
    response.parsed_body
  end

  def test_each_inquiry_step_can_be_left_for_later_without_any_connection
    authenticated do
      update_preference({ purpose: 'inbox' })
      state = response.parsed_body
      assert_equal ['connect', %w[purpose connect facts receive reply complete], 0], [*state.values_at('phase', 'steps'), state.dig('connections', 'count')]
      assert_equal 'facts', skip('connect')['phase']
      state = skip('connect', 'facts')
      assert_equal ['complete', false, %w[facts connect]], state.values_at('phase', 'replied', 'pending')
      refute Facts.new(@account.reload).read['confirmed']
      assert_equal 'facts', skip('connect')['phase']
      assert_equal ['complete', ['connect']], save_facts.values_at('phase', 'pending')
      assert_equal 'connect', skip['phase']
    end
  end

  def test_store_facts_are_reachable_before_choosing_a_purpose_or_connecting
    authenticated do
      assert_equal 'purpose', read_guide['phase']
      state = save_facts
      assert_equal ['purpose', true], [state['phase'], state.dig('facts', 'confirmed')]
      update_preference({ purpose: 'inbox' })
      assert_equal 'connect', response.parsed_body['phase']
      inbox = connect
      assert_equal ['receive', inbox.id], read_guide.values_at('phase', 'inbox_id')
    end
  end

  def test_posting_purpose_asks_for_store_facts_then_posting_then_connection
    authenticated do
      update_preference({ purpose: 'posting' })
      state = response.parsed_body
      assert_equal ['facts', %w[purpose facts posting connect complete]], state.values_at('phase', 'steps')
      assert_equal 'posting', save_facts['phase']
      assert_equal 'connect', skip('posting')['phase']
      connect
      assert_equal ['complete', false], read_guide.values_at('phase', 'replied')
      update_preference({ purpose: 'inbox', dismissed: false })
      state = response.parsed_body
      assert_equal [[], 'receive'], [state.dig('preference', 'skipped'), state['phase']]
    end
  end

  def test_posting_steps_can_each_be_left_for_later
    authenticated do
      update_preference({ purpose: 'posting' })
      assert_equal 'posting', skip('facts')['phase']
      assert_equal 'connect', skip('facts', 'posting')['phase']
      assert_equal ['complete', %w[facts connect]], skip('facts', 'posting', 'connect').values_at('phase', 'pending')
    end
  end

  def test_receive_and_reply_practice_can_be_left_for_later
    authenticated do
      update_preference({ purpose: 'inbox' })
      inbox = connect
      save_facts
      assert_equal 'receive', read_guide['phase']
      assert_equal ['complete', false, inbox.id], skip('receive').values_at('phase', 'replied', 'inbox_id')
      assert_equal 'receive', skip['phase']
      conversation = create(:conversation, account: @account, inbox: inbox)
      create(:message, account: @account, inbox: inbox, conversation: conversation,
                       message_type: :incoming, private: false, source_id: 'received-later@example.test')
      assert_equal 'reply', read_guide['phase']
      assert_equal ['complete', false, conversation.display_id], skip('reply').values_at('phase', 'replied', 'conversation_id')
    end
  end

  def test_left_steps_must_be_known_unique_steps
    authenticated do
      [['purpose'], %w[connect connect], ['complete'], [1]].each do |value|
        update_preference({ purpose: 'inbox', skipped: value })
        assert_response :unprocessable_entity, value.inspect
      end
      assert_nil read_guide.dig('preference', 'skipped')
    end
  end

  def test_connection_list_counts_every_inbox_and_shows_the_forwarding_mail_as_set_up
    address = "shop-#{@account.id}@inbox.staging.toybaco.jp"
    channel = Channel::Email.create!(account: @account, email: address, forward_to_email: address, imap_enabled: false, smtp_enabled: false)
    forwarding = @account.inboxes.create!(channel: channel, name: 'メール')
    @account.update!(internal_attributes: Toybaco::Entitlements.attributes(@account)
                                            .merge(Toybaco::InboundEmail::ATTR_KEY => { 'status' => 'ready', 'address' => address }))
    create(:inbox, account: @account)
    authenticated do
      connections = read_guide['connections']
      assert_equal [2, 2], connections.values_at('count', 'limit')
      # 接続一覧の件数と上限は、Gmail・Microsoft・LINE 代行の上限判定と同じ数え方(転送用メールを含む全受信箱)。
      assert_equal Toybaco::Connections::InboxLimit.reached(@account), connections.values_at('limit', 'count')
      assert_equal %w[email_forward gmail microsoft line web_widget instagram], connections['channels'].pluck('key')
      rows = connections['channels'].index_by { |row| row['key'] }
      assert_equal ['ready', address], rows['email_forward'].values_at('state', 'address')
      assert_equal %w[available preparing available connected preparing],
                   %w[gmail microsoft line web_widget instagram].map { |key| rows[key]['state'] }
      update_preference({ purpose: 'inbox' })
      assert_equal ['connect', %w[facts connect]], response.parsed_body.values_at('phase', 'pending')
      assert_equal 'facts', skip('connect')['phase']
      @account.account_users.find_by!(user: @user).update!(role: :agent)
      forwarding.inbox_members.where(user: @user).delete_all
      staff = read_guide['connections']
      assert_equal [2, 'ready', nil], [staff['count'], staff['channels'].first['state'], staff['channels'].first['address']]
    end
  end

  # 上限の案内の出し分け(無料プランは「有料プランを見る」、それ以外はサポート)に使う印。数え方には使わない。
  def test_connection_list_says_whether_the_plan_is_free
    authenticated do
      assert_equal [true, 2], read_guide['connections'].values_at('free', 'limit')
      terms = Toybaco::PlanCatalog.default.definition('light', '2026-09-25.1')
      Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: 'month'))
      assert_equal [false, 4], read_guide['connections'].values_at('free', 'limit')
    end
  end

  def forwarding_inbox!
    address = "shop-#{@account.id}@inbox.staging.toybaco.jp"
    channel = Channel::Email.create!(account: @account, email: address, forward_to_email: address, imap_enabled: false, smtp_enabled: false)
    @account.update!(internal_attributes: Toybaco::Entitlements.attributes(@account)
                                            .merge(Toybaco::InboundEmail::ATTR_KEY => { 'status' => 'ready', 'address' => address }))
    @account.inboxes.create!(channel: channel, name: 'メール')
  end

  # 開通直後の店舗には転送用メールがあるが、受信・返信まで案内できる窓口ではないため、接続は「まだ」のまま残す。
  def test_forwarding_mail_alone_keeps_the_connection_pending_and_resume_returns_to_it
    forwarding_inbox!
    authenticated do
      update_preference({ purpose: 'inbox' })
      state = skip('connect', 'facts')
      assert_equal ['complete', %w[facts connect], 1], [*state.values_at('phase', 'pending'), state.dig('connections', 'count')]
      assert_equal 'connect', skip('facts')['phase']
      connect
      assert_equal ['facts'], read_guide['pending']
    end
  end

  def test_staff_can_leave_store_facts_for_later
    @user.account_users.find_by!(account: @account).update!(role: :agent)
    authenticated do
      update_preference({ purpose: 'inbox' })
      state = skip('connect')
      assert_equal ['facts', false], [state['phase'], state['administrator']]
      assert_equal ['complete', %w[facts connect]], skip('connect', 'facts').values_at('phase', 'pending')
      refute Facts.new(@account.reload).read['confirmed']
    end
  end

  # 接続できるのは管理者だけ。所属していない受信箱しか無いスタッフにも、店舗にガイドの対象になる受信箱があれば
  # 完了画面に「受信箱の接続」を出さない。転送用メールだけの店舗では、スタッフにも出す。案内の候補(所属で絞る)と段の進み方は変えない。
  def assert_staff_outside_the_store_inbox_is_not_asked_to_connect
    forwarding_inbox!
    @user.account_users.find_by!(account: @account).update!(role: :agent)
    authenticated do
      update_preference({ purpose: 'inbox' })
      assert_equal ['connect', %w[facts connect]], response.parsed_body.values_at('phase', 'pending')
      yield.inbox_members.where(user: @user).delete_all
      assert_equal ['connect', ['facts'], []], read_guide.values_at('phase', 'pending', 'inboxes')
      assert_equal ['complete', ['facts']], skip('connect', 'facts').values_at('phase', 'pending')
    end
  end

  def test_staff_outside_the_gmail_inbox_is_not_asked_to_connect_one
    assert_staff_outside_the_store_inbox_is_not_asked_to_connect { connect }
  end

  def test_staff_outside_the_line_inbox_is_not_asked_to_connect_one
    assert_staff_outside_the_store_inbox_is_not_asked_to_connect { line_inbox }
  end

  def test_posting_step_can_be_resumed_after_it_was_left_for_later
    authenticated do
      update_preference({ purpose: 'posting' })
      save_facts
      assert_equal 'complete', skip('posting', 'connect')['phase']
      assert_equal 'posting', skip('connect')['phase']
    end
  end

  def step_lists(state)
    state['preference'].values_at('skipped', 'opened')
  end

  # 投稿画面を開いた店舗は、投稿の段を済ませたとして先へ進む。「あとで設定する」とは別に記録するので、
  # 完了画面に「投稿の準備 続ける」は出ない(完了画面は skipped にあって opened に無いときだけ出す)。
  def test_opening_the_posting_screen_moves_on_without_leaving_the_step_for_later
    authenticated do
      update_preference({ purpose: 'posting' })
      assert_equal 'posting', save_facts['phase']
      update_preference({ opened: ['posting'] })
      assert_response :success
      assert_equal ['connect', [[], ['posting']]], [response.parsed_body['phase'], step_lists(response.parsed_body)]
      state = skip('connect')
      assert_equal ['complete', [['connect'], ['posting']], ['connect']], [state['phase'], step_lists(state), state['pending']]
      refute_includes state.dig('preference', 'skipped'), 'posting'
    end
  end

  # 「あとで設定する」にした投稿の段は skipped に入り、完了画面の「続ける」(skipped から外す・opened は触らない)で投稿の段へ戻る。
  def test_posting_left_for_later_is_resumed_to_the_posting_step
    authenticated do
      update_preference({ purpose: 'posting' })
      save_facts
      state = skip('posting', 'connect')
      assert_equal ['complete', [%w[posting connect], []]], [state['phase'], step_lists(state)]
      update_preference({ skipped: ['connect'], dismissed: false })
      assert_response :success
      assert_equal ['posting', [['connect'], []]], [response.parsed_body['phase'], step_lists(response.parsed_body)]
      update_preference({ opened: ['posting'] })
      assert_equal ['complete', [['connect'], ['posting']]], [response.parsed_body['phase'], step_lists(response.parsed_body)]
    end
  end

  # 開いて済ませた段の一覧も「あとで」と同じ規則(既知の段・重複なし)。配列以外は、どちらの一覧も黙って捨てずに 422 にする。
  def test_opened_steps_must_be_a_list_of_known_unique_steps
    authenticated do
      [['purpose'], %w[posting posting], ['complete'], [1], 'posting', nil, { posting: true }, [['posting']]].each do |value|
        update_preference({ purpose: 'posting', opened: value })
        assert_response :unprocessable_entity, value.inspect
      end
      ['connect', nil, { connect: true }].each do |value|
        update_preference({ purpose: 'posting', skipped: value })
        assert_response :unprocessable_entity, value.inspect
      end
      assert_equal ['purpose', {}], read_guide.values_at('phase', 'preference')
    end
  end

  # 目的を変えたら、開いて済ませた段も持ち越さない(「あとで」と同じ)。
  def test_changing_the_purpose_clears_opened_steps
    authenticated do
      update_preference({ purpose: 'posting' })
      save_facts
      update_preference({ opened: ['posting'] })
      assert_equal 'connect', response.parsed_body['phase']
      update_preference({ purpose: 'inbox' })
      assert_equal [[], []], step_lists(response.parsed_body)
      update_preference({ purpose: 'posting' })
      assert_equal ['posting', [[], []]], [response.parsed_body['phase'], step_lists(response.parsed_body)]
    end
  end

  def test_instagram_is_listed_by_its_actual_state
    authenticated do
      assert_equal 'preparing', read_guide['connections']['channels'].find { |row| row['key'] == 'instagram' }['state']
      @account.enable_features!('channel_instagram')
      GlobalConfigService.stub(:load, ->(name, default) { name == 'INSTAGRAM_APP_ID' ? 'fixture-app' : default }) do
        assert_equal 'available', read_guide['connections']['channels'].find { |row| row['key'] == 'instagram' }['state']
      end
    end
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
