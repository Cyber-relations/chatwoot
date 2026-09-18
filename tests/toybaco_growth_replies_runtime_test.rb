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
  end

  def set_plan(id)
    terms = Toybaco::PlanCatalog.default.definition(id, '2026-09-18.1')
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
end
