# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require 'ostruct'
require Rails.root.join('lib/toybaco/growth/draft_work')
require Rails.root.join('lib/toybaco/growth/draft_state')
require Rails.root.join('lib/toybaco/growth/ai_grants')
require Rails.root.join('lib/toybaco/growth/trial_example')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoGrowthDraftsRuntimeTest < ActionDispatch::IntegrationTest
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true
  Growth = Toybaco::Growth
  NOW = Time.utc(2026, 9, 19, 2)

  def setup
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    travel_to NOW
    @account = create(:account)
    @owner = create(:user, :administrator, account: @account)
    @inbox = create(:inbox, account: @account)
    @conversation = create(:conversation, account: @account, inbox: @inbox, status: :open).reload
    @incoming = create(:message, account: @account, inbox: @inbox, conversation: @conversation, message_type: :incoming,
                                private: false, content: '営業時間は？', source_id: 'manual-incoming@example.test')
    @facts = Growth::StoreFacts.new(@account).save!({ 'name' => 'テスト店舗', 'hours' => '10時から18時' }, user: @owner)
    terms = Toybaco::PlanCatalog.default.definition('free', '2026-09-18.1')
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: nil))
    @grant = Growth::AiGrants.new(@account).issue!(source: 'included', source_key: 'manual-fixture', units: 20,
                                                 starts_at: NOW - 1, ends_at: NOW + 30.days)
    @calls = []
  end

  def teardown
    travel_back
    Current.reset
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  def start!(user: @owner, nonce: SecureRandom.uuid, draft: '')
    Growth::DraftAccess.stub(:enabled?, true) do
      Growth::DraftStart.new(@account, @conversation, user).create!(nonce: nonce, draft: draft)
    end
  end

  def work!(request, content: '10時から18時までです。', &during)
    model = Object.new
    calls = @calls
    model.define_singleton_method(:generate) do |prompt|
      calls << prompt
      during&.call
      { 'content' => content, 'needs_review' => false }
    end
    Growth::DraftAccess.stub(:enabled?, true) { Growth::DraftWork.new(request, model: model).perform }
  end

  def test_explicit_generation_is_private_and_consumed_once_even_when_job_repeats
    request = start!
    assert_equal 0, @grant.reload.used
    assert_equal 'queued', request.state
    work!(request)
    work!(request.reload)
    result = Growth::DraftState.new(request.reload).read
    assert_equal 'completed', result['state']
    assert_equal '10時から18時までです。', result['content']
    assert_equal 1, @calls.length
    assert_equal 1, @grant.reload.used
    assert_nil request.encrypted_input
    message = @account.messages.find(result['message_id'])
    assert message.private?
    assert_equal @owner, message.sender
    assert_equal 'open', @conversation.reload.status
    assert_empty @conversation.messages.where(message_type: :outgoing, private: false)
  end

  def test_double_click_and_network_replay_reuse_the_same_request
    nonce = SecureRandom.uuid
    first = start!(nonce: nonce)
    assert_equal first.id, start!.id
    work!(first)
    assert_equal first.id, start!(nonce: nonce).id
    next_request = start!
    refute_equal first.id, next_request.id
    work!(next_request)
    assert_equal 2, @grant.reload.used
  end

  def test_pending_changed_draft_never_allocates_another_model_call
    first = start!(draft: '17時まで')
    assert_raises(Growth::DraftStart::Unavailable) { start!(draft: '18時まで') }
    assert_equal 1, Toybaco::GrowthDraftRequest.where(account_id: @account.id).count
    refute_includes first.encrypted_input, '17時まで'
    input = Growth::DraftInput.decrypt(first)
    assert_equal '17時まで', input['draft']
    assert_equal 48, input['token'].length
  end

  def test_permission_loss_during_generation_releases_without_saving_an_answer
    request = start!
    work!(request) { @account.account_users.find_by!(user_id: @owner.id).destroy! }
    assert_equal 'failed', request.reload.state
    assert_equal 'released', request.operation.reload.state
    assert_equal 0, @grant.reload.used
    assert_nil request.encrypted_input
  end

  def test_new_question_during_generation_invalidates_the_result
    request = start!
    work!(request) do
      create(:message, account: @account, inbox: @inbox, conversation: @conversation, message_type: :incoming,
                       private: false, content: '予約は取り消せますか？')
    end
    assert_equal 'failed', request.reload.state
    assert_equal 0, @grant.reload.used
    assert_empty @conversation.messages.where(message_type: :outgoing)
  end

  def test_edited_question_and_changed_facts_are_rejected_before_model_invocation
    request = start!
    @incoming.update!(content: '明日の営業時間は？')
    work!(request)
    assert_empty @calls
    assert_equal 'conversation_changed', request.reload.error_code
    second = start!
    Growth::StoreFacts.new(@account).save!({ 'name' => '変更後' }, user: @owner)
    work!(second)
    assert_empty @calls
    assert_equal 0, @grant.reload.used
  end

  def test_another_staff_reply_during_generation_invalidates_the_old_answer
    request = start!
    work!(request) do
      create(:message, account: @account, inbox: @inbox, conversation: @conversation, sender: @owner,
                       message_type: :outgoing, private: false, content: '担当者より返信済みです。')
    end
    assert_equal 'failed', request.reload.state
    assert_equal 0, @grant.reload.used
    assert_empty @conversation.messages.where(private: true)
  end

  def test_cancellation_during_model_call_never_saves_or_charges_late_output
    request = start!
    work!(request) { Growth::DraftResult.new(request.reload).fail!('cancelled') }
    assert_equal 'cancelled', request.reload.error_code
    assert_equal 'released', request.operation.reload.state
    assert_equal 0, @grant.reload.used
    assert_empty @conversation.messages.where(message_type: :outgoing)
  end

  def test_model_failure_and_unregistered_url_release_the_reservation
    request = start!
    work!(request) { raise Growth::DraftModel::Unavailable, 'fixture failure' }
    assert_equal 'generation_unavailable', request.reload.error_code
    work!(start!, content: 'https://unregistered.example.test/payment')
    assert_equal 0, @grant.reload.used
    assert_empty @conversation.messages.where(message_type: :outgoing)
  end

  def test_expired_lease_and_disabled_feature_do_not_call_the_model
    request = start!
    travel_to NOW + 6.minutes
    Toybaco::GrowthDraftSweepJob.perform_now
    work!(request.reload)
    assert_equal 'expired', request.reload.error_code
    assert_nil request.encrypted_input
    assert_empty @calls
    Growth::DraftAccess.stub(:enabled?, false) do
      assert_raises(Growth::DraftStart::Unavailable) { Growth::DraftStart.new(@account, @conversation, @owner).create!(nonce: SecureRandom.uuid, draft: '') }
    end
  end

  def test_failed_message_persistence_rolls_back_both_the_answer_and_consumption
    request = start!
    invalid = Message.new
    failure = ->(*) { raise ActiveRecord::RecordInvalid, invalid }
    Message.stub(:new, failure) { work!(request) }
    assert_equal 'failed', request.reload.state
    assert_equal 'released', request.operation.reload.state
    assert_equal 0, @grant.reload.used
    assert_empty @conversation.messages.where(message_type: :outgoing)
  end

  def test_context_has_a_bounded_history_and_only_public_messages
    12.times do
      create(:message, account: @account, inbox: @inbox, conversation: @conversation, message_type: :incoming, private: false, content: '字' * 2000)
    end
    create(:message, account: @account, inbox: @inbox, conversation: @conversation, message_type: :outgoing, private: true, content: '秘密の内部メモ')
    input = Growth::DraftInput.new(@account, @conversation, @owner).build('')
    assert_operator input['messages'].sum { |message| message['content'].length }, :<=, 8000
    refute_includes JSON.generate(input['messages']), '秘密の内部メモ'
  end

  def test_api_requires_fresh_conversation_access_same_origin_and_actor_owned_result
    input = { account_id: @account.id, conversation_id: @conversation.display_id, nonce: SecureRandom.uuid, draft: '' }
    session = OpenStruct.new(user: @owner)
    Growth::DraftAccess.stub(:enabled?, true) do
      Toybaco::Oidc::SessionReader.stub(:new, session) do
        get '/toybaco/growth/drafts', params: input.except(:nonce, :draft)
        assert_response :success
        assert_nil response.parsed_body['result']
        assert_empty Toybaco::GrowthDraftRequest.where(account_id: @account.id)
        post '/toybaco/growth/drafts', params: input, headers: { 'Origin' => 'https://foreign.test' }, as: :json
        assert_response :forbidden
        post '/toybaco/growth/drafts', params: input, headers: { 'Origin' => 'http://www.example.com' }, as: :json
        assert_response :accepted
        request_id = response.parsed_body['id']
        session.user = create(:user, :administrator, account: @account)
        get '/toybaco/growth/drafts', params: input.merge(request_id: request_id).except(:nonce, :draft)
        assert_response :not_found
        session.user = @owner
        delete '/toybaco/growth/drafts', params: input.merge(request_id: request_id), headers: { 'Origin' => 'http://www.example.com' }, as: :json
        assert_response :success
        assert_equal 'cancelled', response.parsed_body['error_code']
        get '/toybaco/growth/drafts', params: input.merge(account_id: create(:account).id).except(:nonce, :draft)
        assert_response :forbidden
      end
    end
  end

  def test_agents_need_actual_inbox_access
    agent = create(:user, account: @account, role: 'agent')
    assert_raises(Growth::DraftStart::Unavailable) { start!(user: agent) }
    create(:inbox_member, inbox: @inbox, user: agent)
    assert_equal 'queued', start!(user: agent).state
  end

  def test_verified_manual_answer_is_eligible_as_a_trial_example
    request = start!
    work!(request)
    id = Growth::DraftState.new(request.reload).read.fetch('message_id')
    assert_equal id, Growth::TrialExample.new(@account).find(id, revision: @facts['revision'])&.id
    @incoming.update!(content: '予約変更は？')
    assert_nil Growth::TrialExample.new(@account).find(id, revision: @facts['revision'])
  end
end
