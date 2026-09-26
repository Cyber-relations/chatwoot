# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require 'ostruct'
require_relative 'toybaco_growth_purchase_stripe_fixture'
require Rails.root.join('lib/toybaco/growth/purchase_session')
require Rails.root.join('lib/toybaco/growth/purchase_fulfillment')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoGrowthPurchaseRuntimeTest < ActionDispatch::IntegrationTest
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true
  Intent = Toybaco::Growth::PurchaseIntent
  VERSION = '2026-09-25.1'
  NOW = Time.utc(2026, 9, 18, 12)
  SELECTION = { 'plan_id' => 'standard', 'plan_version' => VERSION, 'cycle' => 'month' }.freeze

  # External Stripe is the only payment boundary replaced here. Accounts,
  # memberships, grants, locks, routes and confirmation state are real Rails.
  StripeFixture = ToybacoGrowthPurchaseStripeFixture

  def setup
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    travel_to NOW
    data = JSON.parse(File.read(Toybaco::PlanCatalog::PATH))
    %w[light standard pro].each do |id|
      data['plans'][id]['versions'][VERSION]['sellable'] = true
      data['current_versions'][id] = VERSION
    end
    @catalog = Toybaco::PlanCatalog.new(data)
    @client = StripeFixture.new(@catalog)
    @account = create(:account)
    @user = create(:user, :administrator, account: @account)
    @account.update!(internal_attributes: { Toybaco::BillingAccess::OWNER_KEY => @user.id })
    terms = @catalog.definition('free', VERSION)
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: nil))
  end

  def teardown
    travel_back
    Current.reset
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  def service(user = @user)
    Toybaco::Growth::PurchaseSession.new(@account, user, client: @client,
                                        environment: { 'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'staging', 'TOYBACO_STRIPE_MODE' => 'test' })
  end

  def start(selection = SELECTION, user: @user)
    Toybaco::PlanCatalog.stub(:default, @catalog) { service(user).start!(selection) }
  end

  def session_id
    Intent.saved(@account.reload)['session_id']
  end

  def fulfill
    Toybaco::Growth::PurchaseFulfillment.new(client: @client).complete!(session_id)
  end

  def test_repeat_start_reuses_one_session_without_granting_paid_rights
    first = start
    assert_equal first, start
    assert_equal 1, @client.sessions.size
    assert_equal 'free', Toybaco::Entitlements.contract_for(@account.reload)['plan_id']
    assert_nil @account.internal_attributes['toybaco_subscription_id']
    assert_equal 0, Toybaco::GrowthAiGrant.where(account_id: @account.id).count
    params = @client.create_requests.first.first
    assert_equal @account.id.to_s, params['client_reference_id']
    assert_equal 'false', params['allow_promotion_codes']
    assert_equal 'card', params['payment_method_types[0]']
    assert_equal 'required', params['consent_collection[terms_of_service]']
    assert_equal Toybaco::LegalTerms::TOS_MESSAGE, params['custom_text[terms_of_service_acceptance][message]']
    assert_equal Toybaco::LegalTerms::SUBMIT_MESSAGE, params['custom_text[submit][message]']
    %w[metadata subscription_data[metadata]].each do |scope|
      assert_equal Toybaco::LegalTerms::VERSION, params["#{scope}[toybaco_terms_version]"]
      assert_equal NOW.iso8601, params["#{scope}[toybaco_terms_accepted_at]"]
    end
    assert_nil Toybaco::Entitlements.attributes(@account.reload)[Toybaco::LegalTerms::KEY], 'checkout alone is not a completed contract'
  end

  def test_timeout_after_creation_keeps_nonce_and_reuses_the_same_remote_session
    @client.fail_after = true
    assert_raises(Toybaco::Checkout::Error) { start }
    before = Intent.saved(@account.reload)
    assert_equal 'prepared', before['state']
    assert_equal 'open', start['state']
    assert_equal before['nonce'], Intent.saved(@account.reload)['nonce']
    assert_equal 1, @client.sessions.size
    assert_equal @client.create_requests.first, @client.create_requests.last
  end

  def test_paid_checkout_upgrades_same_store_once_and_preserves_staff_and_drafts
    teammate = create(:user, account: @account, role: 'agent')
    inbox = create(:inbox, account: @account)
    conversation = create(:conversation, account: @account, inbox: inbox)
    draft = create(:message, message_type: :incoming, account: @account, inbox: inbox, conversation: conversation, content: '保存するお問い合わせ')
    count = Account.count
    start
    subscription_id = @client.pay!(session_id)
    @client.subscriptions[subscription_id]['cancel_at_period_end'] = true
    2.times { assert_equal 'complete', fulfill }
    assert_equal count, Account.count
    assert_equal 'standard', Toybaco::Entitlements.contract_for(@account.reload)['plan_id']
    assert @account.account_users.exists?(user_id: teammate.id)
    assert_equal '保存するお問い合わせ', draft.reload.content
    assert_equal inbox.id, @account.inboxes.first.id
    assert_equal 500, Toybaco::GrowthAiGrant.where(account_id: @account.id).sum(:units)
    assert_equal @user.id, @account.internal_attributes[Toybaco::BillingAccess::OWNER_KEY]
    assert_equal true, @account.internal_attributes['toybaco_cancel_at_period_end']
    assert_equal [{ 'route' => 'growth_purchase', 'terms_version' => Toybaco::LegalTerms::VERSION, 'accepted_at' => NOW.iso8601,
                    'user_id' => @user.id, 'session_id' => session_id, 'stripe_consent' => 'accepted' }],
                 @account.internal_attributes[Toybaco::LegalTerms::KEY], 'repeated fulfilment records the consent once'
  end

  def test_complete_checkout_without_paid_invoice_keeps_free_access
    start
    sub_id = @client.pay!(session_id, paid: false)
    assert_equal 'payment_pending', fulfill
    assert_equal 'free', Toybaco::Entitlements.contract_for(@account.reload)['plan_id']
    assert_equal 0, Toybaco::GrowthAiGrant.where(account_id: @account.id).count
    @client.sessions[session_id]['payment_status'] = 'paid'
    @client.subscriptions[sub_id]['latest_invoice'].merge!('status' => 'paid', 'amount_remaining' => 0)
    assert_equal 'complete', fulfill
  end

  def test_non_owner_and_removed_owner_cannot_purchase_or_receive_checkout_url
    other = create(:user, :administrator, account: @account)
    assert_raises(Intent::Unavailable) { start(user: other) }
    assert_empty @client.sessions
    start
    @user.account_users.find_by!(account: @account).update!(role: :agent)
    assert_raises(Intent::Unavailable) { service.refresh! }
    @client.pay!(session_id)
    assert_raises(Intent::Unavailable) { fulfill }
    assert_equal 'free', Toybaco::Entitlements.contract_for(@account.reload)['plan_id']
  end

  def test_session_cannot_be_transferred_to_a_different_store
    start
    @client.pay!(session_id)
    elsewhere = create(:account)
    @client.sessions[session_id]['metadata']['toybaco_existing_account_id'] = elsewhere.id.to_s
    assert_raises(Intent::Unavailable) { fulfill }
    assert_nil @account.reload.internal_attributes['toybaco_subscription_id']
    assert_nil elsewhere.reload.internal_attributes['toybaco_subscription_id']
  end

  def test_different_selection_waits_until_existing_checkout_is_expired
    start
    assert_raises(Intent::Unavailable) { start(SELECTION.merge('plan_id' => 'pro')) }
    old_id = session_id
    assert_equal 'expired', service.cancel!['state']
    assert_equal 'open', start(SELECTION.merge('plan_id' => 'pro'))['state']
    refute_equal old_id, session_id
    assert_equal 2, @client.sessions.size
  end

  def test_missing_session_is_reconciled_after_expiry_before_a_new_attempt
    @client.fail_before = true
    assert_raises(Toybaco::Checkout::Error) { start }
    travel_to NOW + 2.hours
    @client.fail_before = false
    @client.incomplete_list = true
    assert_raises(Intent::Unavailable) { service.refresh! }
    assert_equal 'prepared', Intent.saved(@account.reload)['state']
    @client.incomplete_list = false
    assert_equal 'expired', service.refresh!['state']
    assert_equal 'no_session_after_expiry', Intent.saved(@account.reload)['resolution']
    assert_equal 'open', start['state']
    assert_equal 1, @client.sessions.size
  end

  def test_browser_routes_require_current_owner_and_same_origin
    Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @user)) do
      get '/toybaco/growth/purchase/state', params: { account_id: @account.id }
      assert_response :success
      assert_equal 'none', response.parsed_body['state']
      post '/toybaco/growth/purchase', params: { account_id: @account.id, selection: SELECTION },
           headers: { 'Origin' => 'https://another.test' }, as: :json
      assert_response :forbidden
      assert_empty @client.sessions
      get '/toybaco/growth/purchase/state', params: { account_id: create(:account).id }
      assert_response :forbidden
    end
  end

  def test_purchase_screen_opens_with_the_published_sales_and_closes_without_them
    # The sales switch (2026-09-26) publishes the growth version: the shipped catalog opens the screen.
    closed = JSON.parse(File.read(Toybaco::PlanCatalog::PATH))
    %w[light standard pro].each do |id|
      closed['current_versions'][id] = '2026-09-06.1'
      closed['plans'][id]['versions']['2026-09-06.1']['sellable'] = true
      closed['plans'][id]['versions'][VERSION]['sellable'] = false
    end
    Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @user)) do
      get '/toybaco/growth/purchase', params: { account_id: @account.id }
      assert_response :success
      assert_includes response.body, '19,800'
      assert_includes response.body, '213,840'
      # As before the switch, a catalog that sells another version keeps it closed.
      Toybaco::PlanCatalog.stub(:default, Toybaco::PlanCatalog.new(closed)) do
        get '/toybaco/growth/purchase', params: { account_id: @account.id }
        assert_response :not_found
      end
    end
  end
end
