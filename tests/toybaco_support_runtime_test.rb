# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'ostruct'
require 'factory_bot_rails'
require Rails.root.join('lib/toybaco/support/context')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoSupportRuntimeTest < ActionDispatch::IntegrationTest
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true

  def setup
    @support_keys = []
    @support_store = ConnectionPool.new(size: 5, timeout: 1) { Redis::Namespace.new('alfred', redis: Redis.new(url: ENV.fetch('REDIS_URL'))) }
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @account = create(:account)
    @user = create(:user, :administrator, account: @account)
    terms = Toybaco::PlanCatalog.default.definition('free', '2026-09-18.1')
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: nil))
  end

  def teardown
    @support_store.with { |connection| connection.del(*@support_keys.uniq) } if @support_keys.any?
    @support_store.shutdown(&:close)
    Current.reset
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  def authenticated(enabled: true, user: @user, ai: false)
    original = GlobalConfigService.method(:load)
    config = lambda do |name, *args|
      case name
      when 'TOYBACO_SUPPORT_ENABLED' then enabled
      when 'TOYBACO_SUPPORT_AI_ENABLED' then ai
      else original.call(name, *args)
      end
    end
    constructor = Toybaco::Support::Capacity.method(:new)
    capacity = lambda do |account_id, user_id|
      result = constructor.call(account_id, user_id, store: @support_store)
      @support_keys.concat(result.instance_variable_get(:@keys))
      result
    end
    Toybaco::Support::Capacity.stub(:new, capacity) do
      GlobalConfigService.stub(:load, config) do
        Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: user)) { yield }
      end
    end
  end

  def read_support(account_id = @account.id)
    get '/toybaco/support', params: { account_id: account_id }
  end

  def ids
    response.parsed_body.fetch('articles').pluck('id')
  end

  def ask(question = '返信はどこから行いますか', origin: 'http://www.example.com')
    post '/toybaco/support', params: { account_id: @account.id, support_question: question },
                            headers: { 'Origin' => origin }, as: :json
  end

  def test_diagnostics_are_bounded_read_only_and_never_claim_delivery_from_configuration
    before = @account.reload.attributes
    operations = Toybaco::GrowthAiOperation.count
    authenticated do
      get '/toybaco/support/diagnostics', params: { account_id: @account.id, article_id: 'first_steps' }
      assert_response :success
      checks = response.parsed_body.fetch('checks')
      assert_equal 3, checks.length
      assert_equal 'attention', checks.find { |row| row['id'] == 'inboxes' }['state']
      assert_equal 'attention', checks.find { |row| row['id'] == 'facts' }['state']
      checks.each { |row| assert_equal %w[id state text], row.keys.sort }
    end
    assert_equal before, @account.reload.attributes
    assert_equal operations, Toybaco::GrowthAiOperation.count
  end

  def test_diagnostics_do_not_expose_other_store_or_unavailable_article
    elsewhere = create(:account)
    authenticated do
      get '/toybaco/support/diagnostics', params: { account_id: elsewhere.id, article_id: 'reply' }
      assert_response :forbidden
      %w[unknown billing gmail].each do |article|
        get '/toybaco/support/diagnostics', params: { account_id: @account.id, article_id: article }
        assert_response :forbidden
      end
    end
  end

  def test_agent_diagnostics_only_include_their_assigned_inboxes
    inbox = create(:inbox, account: @account)
    @account.account_users.find_by!(user_id: @user.id).update!(role: :agent)
    inbox.inbox_members.where(user_id: @user.id).destroy_all
    authenticated do
      get '/toybaco/support/diagnostics', params: { account_id: @account.id, article_id: 'reply' }
      assert_response :success
      assert_equal 'attention', response.parsed_body['checks'].find { |row| row['id'] == 'inboxes' }['state']
      create(:inbox_member, inbox: inbox, user: @user)
      get '/toybaco/support/diagnostics', params: { account_id: @account.id, article_id: 'reply' }
      assert_response :success
      state = response.parsed_body['checks'].find { |row| row['id'] == 'inboxes' }
      assert_equal 'information', state['state']
      refute_includes state['text'], '正常'
    end
  end

  def test_ai_selects_existing_instructions_without_spending_business_quota
    model = Minitest::Mock.new
    model.expect(:generate, { 'article_id' => 'reply' }) { |prompt| prompt['max_tokens'] == 100 }
    grants = Toybaco::GrowthAiGrant.count
    operations = Toybaco::GrowthAiOperation.count
    authenticated(ai: true) do
      Toybaco::Support::Model.stub(:new, model) do
        ask
        assert_response :success
        assert_equal 'reply', response.parsed_body.dig('article', 'id')
        assert_equal 'conversations', response.parsed_body.dig('article', 'action')
      end
    end
    model.verify
    assert_equal grants, Toybaco::GrowthAiGrant.count
    assert_equal operations, Toybaco::GrowthAiOperation.count
  end

  def test_support_ai_does_not_run_for_closed_gate_cross_site_or_private_question
    model = Minitest::Mock.new
    Toybaco::Support::Model.stub(:new, model) do
      authenticated { ask; assert_response :service_unavailable }
      authenticated(ai: true) do
        ask(origin: 'https://outside.test')
        assert_response :forbidden
        ask('連絡先はprivate@example.testです')
        assert_response :unprocessable_entity
      end
    end
    model.verify
  end

  def test_role_revocation_during_inference_removes_the_previously_available_action
    model = Object.new
    user = @user
    account = @account
    model.define_singleton_method(:generate) do |_prompt|
      account.account_users.find_by!(user_id: user.id).update!(role: :agent)
      { 'article_id' => 'staff' }
    end
    authenticated(ai: true) do
      Toybaco::Support::Model.stub(:new, model) do
        ask('スタッフを招待したい')
        assert_response :success
        assert_nil response.parsed_body['article']
        assert response.parsed_body['unresolved']
      end
    end
  end

  def test_revoked_membership_is_checked_after_model_completion
    model = Object.new
    user = @user
    account = @account
    model.define_singleton_method(:generate) do |_prompt|
      account.account_users.find_by!(user_id: user.id).destroy!
      { 'article_id' => 'reply' }
    end
    authenticated(ai: true) do
      Toybaco::Support::Model.stub(:new, model) { ask; assert_response :forbidden }
    end
  end

  def test_model_cannot_invent_a_billing_or_external_action
    model = Minitest::Mock.new
    model.expect(:generate, { 'article_id' => 'refund_and_delete' }) { true }
    authenticated(ai: true) do
      Toybaco::Support::Model.stub(:new, model) do
        ask('返金を確定して')
        assert_response :success
        assert_nil response.parsed_body['article']
        assert response.parsed_body['unresolved']
      end
    end
    model.verify
  end

  def test_read_only_help_does_not_consume_business_ai_or_change_registration
    before = @account.reload.attributes
    grants = Toybaco::GrowthAiGrant.count
    operations = Toybaco::GrowthAiOperation.count
    authenticated do
      3.times do
        read_support
        assert_response :success
        assert_equal 'no-store', response.headers['Cache-Control']
        assert_includes ids, 'first_steps'
        assert_includes ids, 'reply'
      end
    end
    assert_equal before, @account.reload.attributes
    assert_equal grants, Toybaco::GrowthAiGrant.count
    assert_equal operations, Toybaco::GrowthAiOperation.count
  end

  def test_unapproved_providers_are_not_described_as_available
    authenticated do
      Toybaco::Connections::Gmail.stub(:allowed?, false) do
        Toybaco::Connections::Microsoft.stub(:allowed?, false) do
          read_support
          assert_response :success
          refute_includes ids, 'gmail'
          refute_includes ids, 'microsoft'
          assert_includes ids, 'line'
        end
      end
    end
  end

  def test_membership_revocation_and_other_store_are_checked_each_time
    elsewhere = create(:account)
    authenticated do
      read_support(elsewhere.id)
      assert_response :forbidden
      @account.account_users.find_by!(user_id: @user.id).destroy!
      read_support
      assert_response :forbidden
    end
  end

  def test_agent_sees_help_without_admin_connection_or_billing_actions
    @account.account_users.find_by!(user_id: @user.id).update!(role: :agent)
    authenticated do
      read_support
      assert_response :success
      assert_includes ids, 'reply'
      %w[conversation_search conversation_assign conversation_snooze conversation_reopen conversation_labels canned_reply mail_recipients].each do |id|
        assert_includes ids, id
      end
      %w[connection line gmail microsoft facts staff billing inbox_access line_credentials].each { |id| refute_includes ids, id }
    end
  end

  def test_billing_guide_requires_actual_contract_owner
    authenticated do
      read_support
      refute_includes ids, 'billing'
      attrs = @account.reload.internal_attributes.merge('toybaco_billing_owner_user_id' => @user.id)
      @account.update!(internal_attributes: attrs)
      read_support
      assert_includes ids, 'billing'
    end
  end

  def test_suspended_store_still_has_help_without_offering_inactive_operations
    @account.update!(status: :suspended)
    authenticated do
      read_support
      assert_response :success
      assert_includes ids, 'security'
      assert_includes ids, 'login'
      refute response.parsed_body.dig('status', 'account_active')
      assert_includes ids, 'support_usage'
      %w[first_steps connection gmail microsoft staff posting ai reply private_note resolve attachments reply_failed
         conversation_search conversation_assign conversation_snooze conversation_reopen conversation_labels canned_reply
         mail_recipients inbox_access line_credentials].each { |id| refute_includes ids, id }
    end
  end

  def test_feature_closed_unsigned_and_unconfirmed_requests_do_not_receive_store_state
    authenticated(enabled: false) { read_support; assert_response :not_found }
    authenticated(user: nil) { read_support; assert_response :unauthorized }
    @user.update!(confirmed_at: nil)
    authenticated { read_support; assert_response :unauthorized }
  end

  def test_articles_never_return_plan_snapshots_credentials_or_merchant_messages
    secret = 'private-support-fixture-do-not-return'
    @account.update!(internal_attributes: @account.internal_attributes.merge('support_fixture_secret' => secret))
    authenticated do
      read_support
      assert_response :success
      refute_includes response.body, secret
      refute_includes response.body, 'internal_attributes'
      refute_includes response.body, 'stripe'
      assert_equal %w[account_id ai_available articles billing_report reports_available status version], response.parsed_body.keys.sort
      assert_equal false, response.parsed_body.fetch('reports_available')
      assert_equal false, response.parsed_body.fetch('billing_report')
      response.parsed_body.fetch('articles').each do |article|
        assert_equal Toybaco::Support::Knowledge::VERSION, article.fetch('version')
        assert_equal %w[action answer id title version], article.keys.sort
      end
    end
  end
end
