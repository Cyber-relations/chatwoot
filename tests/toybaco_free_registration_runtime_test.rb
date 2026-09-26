# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require Rails.root.join('lib/toybaco/growth/free_registration')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoFreeRegistrationRuntimeTest < ActionDispatch::IntegrationTest
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true
  Registration = Toybaco::Growth::FreeRegistration
  VERSION = '2026-09-25.1'

  def setup
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    data = JSON.parse(File.read(Toybaco::PlanCatalog::PATH))
    data['free_registration_version'] = VERSION
    data['plans']['free']['versions'][VERSION]['sellable'] = true
    @catalog = Toybaco::PlanCatalog.new(data)
    @attributes = { account_name: 'テスト店舗', user_full_name: 'テスト利用者',
                    email: "free-#{SecureRandom.hex(12)}@example.com", password: 'Fixture-password!483' }
  end

  def teardown
    Current.reset
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  def register
    Toybaco::PlanCatalog.stub(:default, @catalog) do
      Registration.new.register!(@attributes)
    end
  end

  def test_registration_opens_only_with_a_released_sellable_free_version
    # The sales switch (2026-09-26) released the free version: the shipped catalog opens registration.
    assert_equal VERSION, Toybaco::PlanCatalog.default.data.fetch('free_registration_version')
    assert Registration.enabled?
    data = JSON.parse(File.read(Toybaco::PlanCatalog::PATH))
    data.delete('free_registration_version')
    # Without a released free version, as before the switch, the route stays closed.
    Toybaco::PlanCatalog.stub(:default, Toybaco::PlanCatalog.new(data)) do
      refute Registration.enabled?
      assert_no_difference('Account.count') do
        post '/toybaco/free/signup', params: @attributes, as: :json
        assert_response :not_found
      end
    end
    # A released version that is not sellable keeps it closed as well.
    data['free_registration_version'] = VERSION
    data['plans']['free']['versions'][VERSION]['sellable'] = false
    Toybaco::PlanCatalog.stub(:default, Toybaco::PlanCatalog.new(data)) { refute Registration.enabled? }
  end

  def test_same_origin_form_registers_without_creating_a_login_session
    controller = Toybaco::FreeRegistrationsController
    previous_protection = controller.allow_forgery_protection
    controller.allow_forgery_protection = true
    Toybaco::PlanCatalog.stub(:default, @catalog) do
      get '/toybaco/free/signup'
      assert_response :success
      token = Nokogiri::HTML(response.body).at_css('input[name=authenticity_token]')['value']
      post '/toybaco/free/signup', params: @attributes.merge(accept_terms: '1')
      assert_response :unprocessable_entity
      assert_nil User.find_by(email: @attributes[:email])
      ChatwootCaptcha.stub(:new, Struct.new(:valid?).new(true)) do
        post '/toybaco/free/signup', params: @attributes.merge(accept_terms: '1', authenticity_token: token)
      end
      assert_redirected_to '/toybaco/free/verify-email'
      assert_nil response.headers['access-token']
      refute User.find_by!(email: @attributes[:email]).confirmed?
    end
  ensure
    controller.allow_forgery_protection = previous_protection
  end

  def test_terms_must_be_accepted_before_registration
    Toybaco::PlanCatalog.stub(:default, @catalog) do
      assert_no_difference('Account.count') do
        post '/toybaco/free/signup', params: @attributes, as: :json
        assert_response :unprocessable_entity
      end
    end
  end

  def test_unconfirmed_registration_has_no_active_store_quota_or_stripe_subscription
    user, account = register
    refute user.confirmed?
    refute account.active?
    assert_equal 'ja', account.locale
    assert_nil account.onboarding_step
    assert_equal 0, Toybaco::GrowthAiGrant.where(account_id: account.id).count
    attrs = Toybaco::Entitlements.attributes(account)
    assert_nil attrs['toybaco_subscription_id']
    assert_equal 'free', attrs.dig('toybaco_contract', 'plan_id')
    assert_equal user.id, attrs['toybaco_billing_owner_user_id']
    assert_equal 'draft', attrs['toybaco_ai_reply_mode']
  end

  def test_registration_keeps_the_catalog_version_and_records_the_accepted_terms_version
    user, account = register
    state = Toybaco::Entitlements.attributes(account)[Registration::KEY]
    assert_equal VERSION, state['terms_version'], 'terms_version remains the free plan catalog version'
    assert_equal Toybaco::LegalTerms::VERSION, state['legal_terms_version']
    assert_equal state['registered_at'], state['terms_accepted_at']
    records = Toybaco::LegalTerms.records(account)
    assert_equal [{ 'route' => 'free_registration', 'terms_version' => Toybaco::LegalTerms::VERSION, 'accepted_at' => state['registered_at'],
                    'user_id' => user.id, 'session_id' => nil, 'stripe_consent' => nil }], records
    Toybaco::PlanCatalog.stub(:default, @catalog) do
      assert user.confirm
      Registration.new.activate!(user.reload, account.reload)
    end
    assert account.reload.active?
    assert_equal records, Toybaco::LegalTerms.records(account), 'email confirmation does not add or rewrite the consent'
  end

  def test_email_confirmation_activates_the_same_store_and_grants_twenty_once
    user, account = register
    original_id = account.id
    Toybaco::PlanCatalog.stub(:default, @catalog) do
      assert user.confirm
      assert account.reload.active?, 'email confirmation must activate without a second user action'
      assert_equal 1, Toybaco::GrowthAiGrant.where(account_id: account.id).count
      Registration.new.activate!(user.reload, account.reload)
      Registration.new.activate!(user.reload, account.reload)
    end
    assert_equal original_id, account.reload.id
    assert account.active?
    assert_equal 'active', account.internal_attributes.dig(Registration::KEY, 'phase')
    grants = Toybaco::GrowthAiGrant.where(account_id: account.id)
    assert_equal 1, grants.count
    assert_equal 20, grants.first.units
  end

  def test_an_unverified_or_different_user_cannot_activate_the_store
    user, account = register
    other = create(:user)
    Registration.new.activate!(user, account)
    Registration.new.activate!(other, account)
    refute account.reload.active?
    assert_equal 0, Toybaco::GrowthAiGrant.where(account_id: account.id).count
  end

  def test_lost_activation_is_repaired_without_resetting_the_period
    user, account = register
    # Simulate a committed email verification whose activation was interrupted.
    user.update_columns(confirmed_at: Time.now.utc)
    Toybaco::PlanCatalog.stub(:default, @catalog) do
      Toybaco::FreeActivationJob.perform_now(user.id)
      first_anchor = account.reload.internal_attributes.dig(Registration::KEY, 'free_anchor')
      Toybaco::FreeActivationJob.perform_now(user.id)
      assert_equal first_anchor, account.reload.internal_attributes.dig(Registration::KEY, 'free_anchor')
    end
    assert account.active?
    assert_equal 1, Toybaco::GrowthAiGrant.where(account_id: account.id).count
  end
end
