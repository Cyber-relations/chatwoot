# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require Rails.root.join('lib/toybaco/growth/post_draft_work')
require Rails.root.join('lib/toybaco/growth/post_draft_state')
require Rails.root.join('lib/toybaco/growth/posting_request')
require Rails.root.join('lib/toybaco/growth/posting_signature')
require Rails.root.join('lib/toybaco/growth/draft_start')
require Rails.root.join('lib/toybaco/growth/draft_result')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoGrowthPostDraftsRuntimeTest < ActionDispatch::IntegrationTest
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true
  Growth = Toybaco::Growth
  NOW = Time.utc(2026, 9, 19, 4)
  ENVIRONMENT = { 'TOYBACO_OIDC_CLIENT_SECRET' => 'fixture-secret-with-32-characters-only',
                  'FRONTEND_URL' => 'https://app.staging.toybaco.jp' }.freeze

  def setup
    @old_env = ENV.to_h.slice(*ENVIRONMENT.keys)
    ENV.update(ENVIRONMENT)
    @old_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    travel_to NOW
    @account = create(:account)
    @owner = create(:user, :administrator, account: @account)
    @organization = Toybaco::PostizSync.deterministic_organization_id(@account.id)
    @editor = SecureRandom.uuid
    @facts = Growth::StoreFacts.new(@account).save!({ 'name' => 'テスト店舗', 'hours' => '10時から18時',
                                                    'booking' => 'https://store.example/booking' }, user: @owner)
    terms = Toybaco::PlanCatalog.default.definition('free', '2026-09-25.1')
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: nil))
    @grant = Growth::AiGrants.new(@account).issue!(source: 'included', source_key: 'post-fixture', units: 20,
                                                 starts_at: NOW - 1, ends_at: NOW + 30.days)
    @calls = []
  end

  def teardown
    ENVIRONMENT.each_key { |key| @old_env.key?(key) ? ENV[key] = @old_env[key] : ENV.delete(key) }
    travel_back
    ActiveJob::Base.queue_adapter = @old_adapter
    Current.reset
  end

  # The second database is a fixture here; the production boundary calls the
  # existing PostizSync verifier, whose two-database contract has its own gate.
  def ready(&block)
    access = lambda do |user:, account:, organization_id:|
      valid = account.id == @account.id && organization_id == @organization && account.account_users.exists?(user_id: user.id)
      raise Toybaco::PostizSync::AccessRevoked unless valid

      { organization_id: organization_id, user_id: Toybaco::PostizSync.deterministic_user_id(user.id), role: 'USER' }
    end
    Growth::DraftAccess.stub(:enabled?, true) do
      Toybaco::PostizSync.stub(:enabled?, true) { Toybaco::PostizSync.stub(:access_context, access, &block) }
    end
  end

  def start!(nonce: SecureRandom.uuid, draft: '', instruction: '秋の新メニューを紹介したいです。', editor: @editor)
    ready do
      Growth::PostDraftStart.new(@account, @owner, organization_id: @organization, editor_id: editor)
                           .create!(nonce: nonce, draft: draft, instruction: instruction)
    end
  end

  def work!(request, content: '秋の新メニューをご用意しました。皆さまのご来店をお待ちしています。', &during)
    model = Object.new
    calls = @calls
    model.define_singleton_method(:generate) do |prompt|
      calls << prompt
      during&.call
      { 'content' => content, 'needs_review' => false }
    end
    ready { Growth::PostDraftWork.new(request, model: model).perform }
  end

  def payload(action = 'state', **extra)
    body = { 'audience' => ENVIRONMENT['FRONTEND_URL'], 'account_id' => @account.id, 'user_id' => @owner.id,
             'organization_id' => @organization, 'editor_id' => @editor, 'action' => action }
    body.merge!('request_id' => nil) if action == 'state'
    body.merge(extra.transform_keys(&:to_s))
  end

  def deliver(body, signature: nil)
    raw = JSON.generate(body)
    stamp = Time.now.to_i
    key = OpenSSL::HMAC.digest('SHA256', ENVIRONMENT['TOYBACO_OIDC_CLIENT_SECRET'], 'toybaco-posting-ai-v1')
    signature ||= "#{stamp}.#{OpenSSL::HMAC.hexdigest('SHA256', key, "POST\n/toybaco/internal/post-drafts\n#{stamp}\n#{raw}")}"
    ready { post '/toybaco/internal/post-drafts', params: raw, headers: { 'CONTENT_TYPE' => 'application/json', 'X-Toybaco-Posting-Signature' => signature } }
  end

  def test_generated_post_is_encrypted_and_shared_allowance_is_consumed_once
    request = start!(draft: '秋のご案内')
    assert_equal 0, @grant.reload.used
    refute_includes request.encrypted_input, '秋のご案内'
    assert_no_difference('Message.count') { 2.times { work!(request.reload) } }
    assert_equal ['completed', 1], [request.reload.state, @grant.reload.used]
    assert_equal 1, @calls.length
    assert_nil request.encrypted_input
    refute_includes request.encrypted_result, '新メニュー'
    result = Growth::PostDraftInput.decrypt(request, kind: 'result')
    assert_includes result['content'], '新メニュー'
    assert_equal 'post_draft', @calls.first.dig('tool_choice', 'name')
    assert_equal '10時から18時', JSON.parse(@calls.first['messages'][0]['content']).dig('confirmed_store', 'hours')
  end

  def test_signed_policy_resolves_current_store_without_accepting_a_browser_account_id
    @account.update_columns(internal_attributes: @account.reload.internal_attributes.merge('postiz' => { 'enabled' => true, 'organization_id' => @organization }))
    body = { 'audience' => ENVIRONMENT['FRONTEND_URL'], 'action' => 'policy',
             'user_id' => @owner.id, 'organization_id' => @organization }
    assert_no_difference('Toybaco::GrowthPostDraft.count') { deliver(body) }
    assert_response :ok
    assert_equal({ 'account_id' => @account.id, 'organization_id' => @organization, 'shared' => true }, response.parsed_body)
    assert_equal 0, @grant.reload.used
    deliver(body.merge('account_id' => @account.id))
    assert_response :unprocessable_entity
    deliver(body.merge('organization_id' => SecureRandom.uuid))
    assert_response :forbidden
    @account.account_users.where(user_id: @owner.id).delete_all
    deliver(body)
    assert_response :forbidden
  end

  def test_policy_distinguishes_legacy_terms_and_denies_ambiguous_store_mapping
    @account.update_columns(internal_attributes: @account.reload.internal_attributes.merge('postiz' => { 'enabled' => true, 'organization_id' => @organization }))
    body = { 'audience' => ENVIRONMENT['FRONTEND_URL'], 'action' => 'policy',
             'user_id' => @owner.id, 'organization_id' => @organization }
    Toybaco::Entitlements.stub(:for_account, { 'ai_meter' => 'legacy' }) { deliver(body) }
    assert_response :ok
    assert_equal false, response.parsed_body['shared']
    other = create(:account)
    create(:account_user, account: other, user: @owner, role: :administrator)
    other.update_columns(internal_attributes: { 'postiz' => { 'enabled' => true, 'organization_id' => @organization } })
    deliver(body)
    assert_response :forbidden
  end

  def test_background_policy_reads_only_the_current_organization_plan
    @account.update_columns(internal_attributes: @account.reload.internal_attributes.merge('postiz' => { 'enabled' => true, 'organization_id' => @organization }))
    body = { 'audience' => ENVIRONMENT['FRONTEND_URL'], 'action' => 'organization_policy', 'organization_id' => @organization }
    assert_no_difference('Toybaco::GrowthPostDraft.count') { deliver(body) }
    assert_response :ok
    assert_equal({ 'organization_id' => @organization, 'shared' => true }, response.parsed_body)
    assert_equal 0, @grant.reload.used
    Toybaco::Entitlements.stub(:for_account, { 'ai_meter' => 'legacy' }) { deliver(body) }
    assert_response :ok
    assert_equal false, response.parsed_body['shared']
    deliver(body.merge('account_id' => @account.id))
    assert_response :unprocessable_entity
    @account.update!(status: :suspended)
    deliver(body)
    assert_response :forbidden
  end

  def test_background_policy_rejects_a_noncanonical_or_unknown_organization
    other = SecureRandom.uuid
    @account.update_columns(internal_attributes: @account.reload.internal_attributes.merge('postiz' => { 'enabled' => true, 'organization_id' => other }))
    body = { 'audience' => ENVIRONMENT['FRONTEND_URL'], 'action' => 'organization_policy', 'organization_id' => other }
    deliver(body)
    assert_response :forbidden
    deliver(body.merge('organization_id' => @organization))
    assert_response :forbidden
  end

  def test_network_replay_and_double_click_reuse_one_generation
    nonce = SecureRandom.uuid
    first = start!(nonce: nonce)
    assert_equal first.id, start!.id
    work!(first)
    assert_equal first.id, start!(nonce: nonce).id
    work!(start!)
    assert_equal 2, @grant.reload.used
    assert_equal 2, @calls.length
  end

  def test_changed_pending_draft_cannot_allocate_another_model_call
    first = start!(draft: '20時まで')
    assert_raises(Growth::PostDraftStart::Unavailable) { start!(draft: '18時まで') }
    assert_equal 1, Toybaco::GrowthPostDraft.count
    assert_equal '20時まで', Growth::PostDraftInput.decrypt(first)['draft']
    assert_equal 0, @grant.reload.used
  end

  def test_reply_and_post_compete_for_the_same_last_generation
    @grant.update!(units: 1)
    inbox = create(:inbox, account: @account)
    conversation = create(:conversation, account: @account, inbox: inbox, status: :open).reload
    create(:message, account: @account, inbox: inbox, conversation: conversation, message_type: :incoming, private: false, content: '営業時間は？')
    reply = ready { Growth::DraftStart.new(@account, conversation, @owner).create!(nonce: SecureRandom.uuid, draft: '') }
    assert_raises(Growth::PostDraftStart::Unavailable) { start! }
    Growth::DraftResult.new(reply).fail!('cancelled')
    work!(start!)
    assert_equal 1, @grant.reload.used
    assert_equal 0, Growth::AiLedger.new(@account).summary.fetch('remaining')
  end

  def test_revised_store_facts_before_and_during_generation_release_allowance
    first = start!
    Growth::StoreFacts.new(@account).save!({ 'name' => '更新店舗' }, user: @owner)
    work!(first)
    assert_empty @calls
    assert_equal 'context_changed', first.reload.error_code
    second = start!
    work!(second) { Growth::StoreFacts.new(@account).save!({ 'name' => '再更新店舗' }, user: @owner) }
    assert_equal 'failed', second.reload.state
    assert_equal 0, @grant.reload.used
    assert_nil second.encrypted_result
  end

  def test_membership_loss_during_generation_prevents_result_and_charge
    request = start!
    work!(request) { @account.account_users.where(user_id: @owner.id).delete_all }
    assert_equal 'failed', request.reload.state
    assert_equal 'released', request.operation.reload.state
    assert_equal 0, @grant.reload.used
    assert_nil request.encrypted_result
  end

  def test_cancel_during_generation_releases_without_overwriting_user_draft
    request = start!(draft: '人が作成中の文章')
    work!(request) { Growth::PostDraftResult.new(request).fail!('cancelled') }
    assert_equal ['failed', 'cancelled'], [request.reload.state, request.error_code]
    assert_equal 0, @grant.reload.used
    assert_nil request.encrypted_result
  end

  def test_unexpected_url_fails_without_consuming_a_generation
    request = start!
    work!(request, content: '予約はこちら https://invented.invalid/pay')
    assert_equal ['failed', 'generation_unavailable'], [request.reload.state, request.error_code]
    assert_equal 0, @grant.reload.used
  end

  def test_expired_or_crashed_job_is_released_and_never_runs_again
    request = start!
    work = -> { work!(request) { raise SystemExit, 'fixture worker stopped' } }
    assert_raises(SystemExit, &work)
    assert_equal 'running', request.reload.state
    travel_to NOW + 301.seconds
    Toybaco::GrowthPostDraftSweepJob.perform_now
    work!(request.reload)
    assert_equal ['failed', 'expired'], [request.reload.state, request.error_code]
    assert_nil request.encrypted_input
    assert_equal 1, @calls.length
    assert_equal 0, @grant.reload.used
  end

  def test_result_expires_after_one_day_without_resetting_consumption_or_nonce
    nonce = SecureRandom.uuid
    request = start!(nonce: nonce)
    work!(request)
    travel_to NOW + 24.hours
    Toybaco::GrowthPostDraftSweepJob.perform_now
    assert_nil request.reload.encrypted_result
    assert_equal request.id, start!(nonce: nonce).id
    assert_equal 1, @grant.reload.used
    deliver(payload(request_id: request.id))
    assert_response :success
    assert_equal 'expired', response.parsed_body.dig('result', 'error_code')
    refute response.parsed_body['result'].key?('content')
  end

  def test_copied_encrypted_payload_cannot_be_used_for_another_editor_request
    first = start!
    second = start!(editor: SecureRandom.uuid)
    second.update!(encrypted_input: first.encrypted_input)
    work!(second)
    assert_empty @calls
    assert_equal 'failed', second.reload.state
    assert_equal 'released', second.operation.reload.state
    assert_equal 'queued', first.reload.state
    assert_equal 0, @grant.reload.used
  end

  def test_copied_encrypted_result_is_not_exposed_by_state
    first = start!
    second = start!(editor: SecureRandom.uuid)
    work!(first)
    work!(second)
    second.update!(encrypted_result: first.encrypted_result)
    deliver(payload(editor_id: second.editor_id, request_id: second.id))
    assert_response :success
    assert_equal 'generation_unavailable', response.parsed_body.dig('result', 'error_code')
    refute response.parsed_body['result'].key?('content')
    assert_equal 2, @grant.reload.used
  end

  def test_real_signed_routes_create_recover_and_cancel_the_same_request
    body = payload('start', nonce: SecureRandom.uuid, draft: '', instruction: '新メニューのご案内')
    deliver(body)
    assert_response :accepted
    id = response.parsed_body.dig('result', 'id')
    assert_equal 'queued', response.parsed_body.dig('result', 'state')
    assert_equal 19, response.parsed_body['remaining']
    deliver(body)
    assert_response :accepted
    assert_equal id, response.parsed_body.dig('result', 'id')
    deliver(payload('cancel', request_id: id))
    assert_response :success
    assert_equal 'cancelled', response.parsed_body.dig('result', 'error_code')
    assert_equal 20, response.parsed_body['remaining']
    assert_nil Toybaco::GrowthPostDraft.find(id).encrypted_input
  end

  def test_wrong_signature_actor_organization_or_editor_never_exposes_a_result
    request = start!
    work!(request)
    deliver(payload(request_id: request.id), signature: "#{NOW.to_i}.#{'0' * 64}")
    assert_response :unauthorized
    deliver(payload(request_id: request.id, account_id: create(:account).id))
    assert_response :forbidden
    deliver(payload(request_id: request.id, organization_id: SecureRandom.uuid))
    assert_response :forbidden
    deliver(payload(request_id: request.id, editor_id: SecureRandom.uuid))
    assert_response :not_found
    other = create(:user, account: @account)
    deliver(payload(request_id: request.id, user_id: other.id))
    assert_response :not_found
  end

  def test_unconfirmed_facts_and_unknown_payload_fields_cannot_start_generation
    @account.update!(internal_attributes: Toybaco::Entitlements.attributes(@account).except(Growth::StoreFacts::KEY))
    assert_raises(ArgumentError) { start! }
    deliver(payload('start', nonce: SecureRandom.uuid, draft: '', instruction: '原稿', facts: { name: 'untrusted' }))
    assert_response :unprocessable_entity
    assert_equal 0, Toybaco::GrowthPostDraft.count
    assert_equal 0, @grant.reload.used
  end
end
