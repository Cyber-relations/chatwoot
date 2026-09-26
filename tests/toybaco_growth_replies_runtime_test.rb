# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require 'ostruct'
require Rails.root.join('lib/toybaco/growth/bot_reply')
require Rails.root.join('lib/toybaco/growth/ai_grants')
require Rails.root.join('lib/toybaco/growth/reply_job_boundary')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoGrowthRepliesRuntimeTest < ActionDispatch::IntegrationTest
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true
  NOW = Time.utc(2026, 9, 19, 1)
  Growth = Toybaco::Growth

  def setup
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    travel_to NOW
    @account = create(:account)
    @admin = create(:user, :administrator, account: @account)
    @inbox = create(:inbox, account: @account)
    @bot = create(:agent_bot, account: @account)
    create(:agent_bot_inbox, inbox: @inbox, agent_bot: @bot)
    @conversation = create(:conversation, account: @account, inbox: @inbox, status: :pending).reload
    @incoming = create(:message, account: @account, inbox: @inbox, conversation: @conversation,
                                message_type: :incoming, private: false, content: '営業時間は？')
    Growth::StoreFacts.new(@account).save!({ 'name' => 'テスト店舗', 'hours' => '10時から18時' }, user: @admin)
    set_plan('standard')
    @grant = Growth::AiGrants.new(@account).issue!(source: 'included', source_key: 'replies-fixture', units: 2,
                                                 starts_at: NOW - 60, ends_at: NOW + 1.day)
    Toybaco::AiReplyMode.write_to!(@account, 'draft')
  end

  def teardown
    travel_back
    Current.reset
    ActiveJob::Base.queue_adapter = @previous_adapter
    GlobalConfig.clear_cache
  end

  def set_plan(id)
    terms = Toybaco::PlanCatalog.default.definition(id, '2026-09-25.1')
    contract = Toybaco::Entitlements.snapshot_for(terms, cycle: id == 'free' ? nil : 'month')
    Toybaco::Entitlements.apply!(@account, contract)
  end

  def service
    Growth::BotReply.new(@account, bot: @bot, conversation: @conversation, message: @incoming)
  end

  def reserve
    service.update(action_type: 'reserve')
  end

  def complete(reservation, reply: '10時から18時までです。', mode: 'draft')
    service.update(action_type: 'consumed', operation_id: reservation['operation_id'], token: reservation['token'], reply: reply, mode: mode)
  end

  def result_message(reservation)
    reference = Toybaco::GrowthAiOperation.find(reservation['operation_id']).result_reference
    @account.messages.find(reference.delete_prefix('message:'))
  end

  def test_draft_and_one_unit_are_saved_together_and_repeat_does_not_duplicate
    reservation = reserve
    assert_equal 'business_generation', reservation['meter']
    assert_equal '10時から18時', reservation.dig('facts', 'hours')
    assert_equal 'consumed', complete(reservation)['result']
    message = result_message(reservation)
    assert message.private?
    assert_equal @bot, message.sender
    assert_equal Growth::ReplyResult::DRAFT_PREFIX + '10時から18時までです。', message.content
    assert_equal 'open', @conversation.reload.status
    assert_equal 'duplicate', complete(reservation)['result']
    assert_equal 1, @conversation.messages.where(message_type: :outgoing).count
    assert_equal 1, @grant.reload.used
  end

  def test_invalid_result_rolls_back_the_message_and_consumption
    reservation = reserve
    assert_raises(ArgumentError) { complete(reservation, reply: '') }
    assert_equal 0, @grant.reload.used
    assert_equal 'reserved', Toybaco::GrowthAiOperation.find(reservation['operation_id']).state
    assert_empty @conversation.messages.where(message_type: :outgoing)
    assert_equal 'consumed', complete(reservation)['result']
  end

  def test_changed_facts_releases_without_publishing
    reservation = reserve
    Growth::StoreFacts.new(@account).save!({ 'name' => '変更後', 'hours' => '12時から' }, user: @admin)
    assert_equal 'released', complete(reservation)['result']
    assert_equal 0, @grant.reload.used
    assert_empty @conversation.messages.where(message_type: :outgoing)
  end

  def test_human_takeover_during_generation_keeps_the_conversation_open
    reservation = reserve
    @conversation.open!
    assert_equal 'released', complete(reservation)['result']
    assert_equal 0, @grant.reload.used
    assert_empty @conversation.messages.where(message_type: :outgoing)
  end

  def test_newer_customer_message_prevents_answering_an_old_input
    reservation = reserve
    create(:message, account: @account, inbox: @inbox, conversation: @conversation, message_type: :incoming, private: false)
    assert_equal 'released', complete(reservation)['result']
    assert_empty @conversation.messages.where(message_type: :outgoing)
  end

  def test_edited_input_releases_the_old_generation
    reservation = reserve
    @incoming.update!(content: '予約の取り消しは？')
    assert_equal 'released', complete(reservation)['result']
    assert_equal 0, @grant.reload.used
    assert_empty @conversation.messages.where(message_type: :outgoing)
  end

  def change_mode(value, origin: 'http://www.example.com')
    Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @admin)) do
      put '/toybaco/ai_reply_mode', params: { account_id: @account.id, mode: value }, headers: { 'Origin' => origin }, as: :json
    end
  end

  def test_mode_requires_same_origin_and_an_explicit_known_value
    change_mode('auto', origin: 'https://elsewhere.test')
    assert_response :forbidden
    change_mode('surprise')
    assert_response :unprocessable_entity
    assert_equal 'draft', Toybaco::AiReplyMode.read_from(@account.reload)
    change_mode('auto')
    assert_response :success
    assert_equal 'auto', Toybaco::AiReplyMode.read_from(@account.reload)
  end

  def test_free_cannot_enable_automatic_until_its_trial_actually_starts
    set_plan('free')
    change_mode('auto')
    assert_response :unprocessable_entity
    refute Growth::UsageSummary.new(@account.reload).read['automatic_enabled']
    Growth::AiGrants.new(@account).issue!(source: 'trial', source_key: 'start-fixture', units: 100,
                                       starts_at: NOW, ends_at: NOW + 14.days)
    change_mode('auto')
    assert_response :success
    assert Growth::UsageSummary.new(@account.reload).read['automatic_enabled']
    change_mode('draft')
    assert_response :success
  end

  def test_automatic_requires_confirmed_store_facts
    @account.update!(internal_attributes: @account.internal_attributes.except(Growth::StoreFacts::KEY))
    change_mode('auto')
    assert_response :unprocessable_entity
    assert_equal 'facts_required', Growth::UsageSummary.new(@account.reload).read['automatic_reason']
    assert_equal 'facts_required', reserve['reason']
    change_mode('draft')
    assert_response :success
  end

  def test_free_has_manual_ai_but_no_automatic_right_without_trial
    set_plan('free')
    Toybaco::AiReplyMode.write_to!(@account, 'auto')
    assert_equal 'denied', reserve['result']
    Toybaco::AiReplyMode.write_to!(@account, 'draft')
    assert_equal 'reserved', reserve['result']
  end

  def test_automatic_result_is_claimed_only_once_before_external_delivery
    Toybaco::AiReplyMode.write_to!(@account, 'auto')
    reservation = reserve
    assert_equal 'consumed', complete(reservation, mode: 'auto')['result']
    message = result_message(reservation)
    refute message.private?
    delivery = Growth::ReplyDelivery.new(message)
    assert delivery.claim!
    refute Growth::ReplyDelivery.new(message.reload).claim!
    delivery.attempted!(uncertain: true)
    refute Growth::ReplyDelivery.new(message.reload).claim!
    assert_equal 'uncertain', message.additional_attributes.dig(Growth::ReplyResult::KEY, 'state')
    assert_equal 1, @grant.reload.used
  end

  def test_mode_changed_before_delivery_keeps_generated_text_as_private_draft
    Toybaco::AiReplyMode.write_to!(@account, 'auto')
    reservation = reserve
    complete(reservation, mode: 'auto')
    Toybaco::AiReplyMode.write_to!(@account, 'draft')
    message = result_message(reservation)
    refute Growth::ReplyDelivery.new(message).claim!
    assert message.reload.private?
    assert message.content.start_with?(Growth::ReplyResult::DRAFT_PREFIX)
    assert_equal 'open', @conversation.reload.status
  end

  def test_real_send_job_dispatches_a_saved_result_once
    Toybaco::AiReplyMode.write_to!(@account, 'auto')
    reservation = reserve
    complete(reservation, mode: 'auto')
    message = result_message(reservation)
    calls = []
    provider = Object.new
    provider.define_singleton_method(:perform) { calls << 'provider-called' }
    service_class = SendReplyJob::CHANNEL_SERVICES.fetch(@inbox.channel.class.to_s)
    service_class.stub(:new, provider) { 2.times { SendReplyJob.perform_now(message.id) } }
    assert_equal ['provider-called'], calls
    assert_equal 'attempted', message.reload.additional_attributes.dig(Growth::ReplyResult::KEY, 'state')
  end

  def test_trial_expiry_before_delivery_stops_automatic_send
    @grant.update!(revoked_at: NOW)
    set_plan('free')
    Growth::AiGrants.new(@account).issue!(source: 'trial', source_key: 'trial-fixture', units: 100, starts_at: NOW - 1, ends_at: NOW + 2)
    Toybaco::AiReplyMode.write_to!(@account, 'auto')
    Growth::TrialConnection.stub(:allowed?, true) do
      reservation = reserve
      complete(reservation, mode: 'auto')
      message = result_message(reservation)
      travel_to NOW + 3
      refute Growth::ReplyDelivery.new(message).claim!
      assert message.reload.private?
    end
  end

  def test_browser_cannot_settle_using_cookie_and_foreign_bot_cannot_access_the_store
    post '/toybaco/ai_usage', params: { account_id: @account.id, conversation_id: @conversation.display_id,
                                     message_id: @incoming.id, action_type: 'reserve' }, as: :json
    assert_response :unauthorized
    other_bot = create(:agent_bot)
    post '/toybaco/ai_usage', params: { account_id: @account.id, conversation_id: @conversation.display_id,
                                     message_id: @incoming.id, action_type: 'reserve' },
         headers: { 'api_access_token' => other_bot.access_token.token }, as: :json
    assert_response :unauthorized
    assert_empty Toybaco::GrowthAiOperation.where(account_id: @account.id)
  end

  def test_real_bot_api_persists_the_result_without_a_separate_message_post
    input = { account_id: @account.id, conversation_id: @conversation.display_id, message_id: @incoming.id }
    headers = { 'api_access_token' => @bot.access_token.token }
    post '/toybaco/ai_usage', params: input.merge(action_type: 'reserve'), headers: headers, as: :json
    assert_response :success
    reservation = response.parsed_body
    post '/toybaco/ai_usage', params: input.merge(action_type: 'consumed', operation_id: reservation['operation_id'],
                                                token: reservation['token'], reply: '10時からです。', mode: 'draft'), headers: headers, as: :json
    assert_response :success
    assert_equal 'consumed', response.parsed_body['result']
    assert_equal true, response.parsed_body['persisted']
    assert result_message(reservation).private?
    assert_equal 1, @grant.reload.used
    get '/toybaco/ai_usage', params: { account_id: @account.id }, headers: headers
    assert_response :success
    assert_equal 'business_generation', response.parsed_body['meter']
    assert_equal 'contract', response.parsed_body['period']
    assert_equal 1, response.parsed_body['remaining']
  end

  # U2: the AI bot Lambda asks Rails whether it may answer an inbox of a store outside its static list.
  def bot_access_flag(value)
    record = InstallationConfig.find_or_initialize_by(name: 'TOYBACO_GROWTH_BOT_ACCESS_ENABLED')
    record.value = value
    record.save!
    GlobalConfig.clear_cache
  end

  def bot_mode(inbox_id: @inbox.id, bot: @bot)
    get '/toybaco/ai_reply_mode', params: { account_id: @account.id, inbox_id: inbox_id }.compact,
                                  headers: { 'api_access_token' => bot.access_token.token }
    response
  end

  def bot_access(**)
    bot_mode(**)
    assert_response :success
    response.parsed_body['access']
  end

  def access_log
    output = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(output)
    yield
    output.string.lines.grep(/toybaco_bot_access/)
  ensure
    Rails.logger = previous
  end

  def test_bot_mode_adds_access_only_when_the_bot_names_an_inbox
    bot_access_flag(true)
    Toybaco::AiReplyMode.write_to!(@account, 'auto')
    expected = Toybaco::AiReplyMode.payload('auto').merge('meter' => Toybaco::GrowthTerms::METER)
    Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @admin)) do
      get '/toybaco/ai_reply_mode', params: { account_id: @account.id, inbox_id: @inbox.id }
    end
    assert_response :success
    assert_equal expected, response.parsed_body, 'the staff (cookie) answer is unchanged'
    [nil, '', '0', '-1', 'abc', "#{@inbox.id}x"].each do |value|
      assert_equal expected, bot_mode(inbox_id: value).parsed_body, "no access without a valid inbox ID: #{value.inspect}"
    end
    assert_equal expected.merge('access' => { 'allowed' => true, 'reason' => 'included' }), bot_mode.parsed_body
    # The Lambda reads this meter as the object whose unit names the shared generation meter.
    assert_equal 'business_generation', response.parsed_body.dig('meter', 'unit')
    bot_mode(bot: create(:agent_bot))
    assert_response :unauthorized, 'a bot without an inbox of this store is refused as before'
  end

  def test_bot_access_reasons_before_the_rights_check
    Toybaco::AiReplyMode.write_to!(@account, 'auto')
    assert_equal({ 'allowed' => false, 'reason' => 'disabled' }, bot_access, 'closed while the DB flag is unset')
    [false, 'true'].each do |value|
      bot_access_flag(value)
      assert_equal 'disabled', bot_access['reason'], "only the boolean true opens it: #{value.inspect}"
    end
    bot_access_flag(true)
    # D1: a Standard contract with the Lambda bot on the inbox is allowed, as BotReply and ReplyDelivery allow it.
    assert_equal({ 'allowed' => true, 'reason' => 'included' }, bot_access)
    other = create(:inbox, account: create(:account))
    [other.id, other.id + 1_000_000, '9' * 25].each do |id|
      assert_equal({ 'allowed' => false, 'reason' => 'inbox_unknown' }, bot_access(inbox_id: id), "not an inbox of this store: #{id}")
    end
    second = create(:inbox, account: @account)
    assert_equal({ 'allowed' => false, 'reason' => 'bot_not_assigned' }, bot_access(inbox_id: second.id))
    create(:agent_bot_inbox, inbox: second, agent_bot: create(:agent_bot, account: @account))
    assert_equal 'bot_not_assigned', bot_access(inbox_id: second.id)['reason'], 'another bot on the inbox does not count'
    @inbox.agent_bot_inbox.update!(status: :inactive)
    assert_equal 'bot_not_assigned', bot_access['reason'], 'an inactive assignment does not count'
    @inbox.agent_bot_inbox.update!(status: :active)
    Toybaco::AiReplyMode.write_to!(@account, 'draft')
    assert_equal({ 'allowed' => false, 'reason' => 'mode_draft' }, bot_access)
    Toybaco::AiReplyMode.write_to!(@account, 'auto')
    @account.update!(status: :suspended)
    assert_equal({ 'allowed' => false, 'reason' => 'not_growth' }, bot_access)
    @account.update!(status: :active)
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(Toybaco::PlanCatalog.default.legacy('standard'), cycle: 'month'))
    assert_equal({ 'allowed' => false, 'reason' => 'not_growth' }, bot_access, 'an older contract stays on the static list')
    assert_nil response.parsed_body['meter']
  end

  def test_bot_access_logs_one_line_of_ids_and_the_result
    bot_access_flag(true)
    Toybaco::AiReplyMode.write_to!(@account, 'auto')
    lines = access_log { bot_access }
    assert_equal ["toybaco_bot_access account=#{@account.id} inbox=#{@inbox.id} bot=#{@bot.id} allowed=true reason=included\n"], lines
    assert_empty access_log { bot_mode(inbox_id: nil) }, 'nothing is decided without an inbox'
  end
end
