# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/toybaco/checkout/plan_change')

RSpec.describe 'Toybaco authenticated plan changes', type: :request do
  let(:account) { create(:account, internal_attributes: { 'toybaco_subscription_id' => 'sub_fixture' }) }
  let(:user) { create(:user, account: account) }
  let(:service) { instance_double(Toybaco::Checkout::PlanChange) }
  let(:headers) { { 'Origin' => 'http://www.example.com', 'Sec-Fetch-Site' => 'same-origin' } }
  let(:selection) { { 'plan_id' => 'standard', 'plan_version' => '2026-09-06.1', 'cycle' => 'month' } }
  let(:quote) do
    { 'account_id' => account.id, 'user_id' => user.id, 'created_at' => Time.now.to_i, 'operation' => 'fixture',
      'target_name' => 'スタンダード', 'target_amount' => 29_800, 'amount_due' => 4321, 'selection' => selection,
      'policy' => { 'kind' => 'upgrade' }, 'period_end' => Time.now.to_i + 3600, 'internal_field' => 'not public' }
  end

  around do |example|
    original = ENV.fetch('TOYBACO_STRIPE_KEY', nil)
    ENV['TOYBACO_STRIPE_KEY'] = 'fixture-billing-key'
    example.run
  ensure
    original ? ENV['TOYBACO_STRIPE_KEY'] = original : ENV.delete('TOYBACO_STRIPE_KEY')
  end

  before do
    reader = instance_double(Toybaco::Oidc::SessionReader, user: user)
    allow(Toybaco::Oidc::SessionReader).to receive(:new).and_return(reader)
    user.account_users.find_by!(account: account).update!(role: :administrator)
    account.update!(internal_attributes: account.internal_attributes.merge(Toybaco::BillingAccess::OWNER_KEY => user.id))
    allow(Toybaco::Checkout::PlanChange).to receive(:new).and_return(service)
  end

  def change(action, params = {}, account_id: account.id, origin_headers: headers)
    post "/toybaco/billing/change_#{action}?account_id=#{account_id}", params: params, headers: origin_headers, as: :json
  end

  def billing_access
    get '/toybaco/billing/access', params: { account_id: account.id }
    expect(response).to have_http_status(:ok)
    expect(response.headers['Cache-Control']).to eq('no-store')
    response.parsed_body
  end

  def expect_all_billing_denied
    expect(Toybaco::Checkout::Client).not_to receive(:new)
    expect(Net::HTTP).not_to receive(:start)
    get '/toybaco/billing', params: { account_id: account.id }
    expect(response).to have_http_status(:forbidden)
    %w[portal cancel change_preview change_confirm change_refresh change_cancel].each do |action|
      post "/toybaco/billing/#{action}?account_id=#{account.id}", params: {}, headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  it '契約本人にだけ閲覧と管理のbooleanを返し、課金情報を返さない' do
    expect(billing_access).to eq('can_view_billing' => true, 'can_manage_billing' => true)
    user.account_users.find_by!(account: account).update!(role: :agent)
    expect(billing_access).to eq('can_view_billing' => true, 'can_manage_billing' => false)
  end

  it '別の管理者と担当者は直接URLでも契約表示と全操作を利用できない' do
    account.update!(internal_attributes: account.internal_attributes.merge(Toybaco::BillingAccess::OWNER_KEY => create(:user).id))
    %i[administrator agent].each do |role|
      user.account_users.find_by!(account: account).update!(role: role)
      expect(billing_access).to eq('can_view_billing' => false, 'can_manage_billing' => false)
      expect_all_billing_denied
    end
  end

  it '契約本人の記録が未設定または不正でも現在の管理者へ自動付与しない' do
    [nil, 0, -1, user.id.to_s, [user.id], { 'user_id' => user.id }].each do |owner|
      account.update!(internal_attributes: account.internal_attributes.merge(Toybaco::BillingAccess::OWNER_KEY => owner))
      expect(billing_access).to eq('can_view_billing' => false, 'can_manage_billing' => false)
      expect_all_billing_denied
    end
    account.update!(internal_attributes: account.internal_attributes.except(Toybaco::BillingAccess::OWNER_KEY))
    expect(billing_access).to eq('can_view_billing' => false, 'can_manage_billing' => false)
    expect_all_billing_denied
    expect(account.reload.internal_attributes).not_to have_key(Toybaco::BillingAccess::OWNER_KEY)
  end

  it 'accessも未ログインと別店舗の参照を拒否する' do
    other = create(:account, internal_attributes: { Toybaco::BillingAccess::OWNER_KEY => user.id })
    get '/toybaco/billing/access', params: { account_id: other.id }
    expect(response).to have_http_status(:forbidden)
    get '/toybaco/billing/access', params: { account_id: 'invalid' }
    expect(response).to have_http_status(:bad_request)
    allow(Toybaco::Oidc::SessionReader).to receive(:new).and_return(instance_double(Toybaco::Oidc::SessionReader, user: nil))
    get '/toybaco/billing/access', params: { account_id: account.id }
    expect(response).to have_http_status(:unauthorized)
  end

  it 'アカウントAPIの課金属性も契約本人に限り通常業務の設定と機能は保持する' do
    account.update!(custom_attributes: { 'plan_name' => 'Private billing plan', 'subscribed_quantity' => 9,
                                         'subscription_status' => 'active', 'subscription_ends_on' => '2099-01-01',
                                         'website' => 'https://example.invalid' })
    billing_keys = %w[plan_name subscribed_quantity subscription_status subscription_ends_on billing_currency]
    get "/api/v1/accounts/#{account.id}", headers: user.create_new_auth_token
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('custom_attributes', 'plan_name')).to eq('Private billing plan')
    [create(:user).id, nil].each do |owner|
      account.update!(internal_attributes: account.internal_attributes.merge(Toybaco::BillingAccess::OWNER_KEY => owner))
      get "/api/v1/accounts/#{account.id}", headers: user.create_new_auth_token
      expect(response).to have_http_status(:ok)
      attrs = response.parsed_body.fetch('custom_attributes')
      expect(attrs.keys & billing_keys).to be_empty
      expect(attrs.fetch('website')).to eq('https://example.invalid')
      expect(response.parsed_body).to include('features', 'settings', 'status')
      expect(response.parsed_body).not_to have_key('internal_attributes')
    end
  end

  it '契約本人は担当者権限でも請求を閲覧できるが支払変更と契約変更はできない' do
    Toybaco::Entitlements.apply!(account, Toybaco::Entitlements.snapshot_for(Toybaco::PlanCatalog.default.sale('light', 'month'), cycle: 'month'))
    user.account_users.find_by!(account: account).update!(role: :agent)
    client = instance_double(Toybaco::Checkout::Client, retrieve_subscription: {})
    allow(Toybaco::Checkout::Client).to receive(:new).and_return(client)
    allow(Toybaco::BillingSubscription).to receive(:summarize).and_return(status_label: '有効', cancel_at_period_end: false, items: [],
                                                                          invoice: { total: 1234, amount_paid: 1234 })
    get '/toybaco/billing', params: { account_id: account.id }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('直近の請求額（税込）', '1,234', '契約の変更には管理者権限が必要です。')
    expect(response.body).not_to include('id="portal"', 'id="cancel-box"', 'id="plan-change-panel"')
    %w[portal cancel change_preview change_confirm change_refresh change_cancel].each do |action|
      post "/toybaco/billing/#{action}?account_id=#{account.id}", params: {}, headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  it '通常のaccount更新とprofile取得から契約者を変更したり契約値を取得できない' do
    other_owner = create(:user).id
    account.update!(internal_attributes: account.internal_attributes.merge(Toybaco::BillingAccess::OWNER_KEY => other_owner))
    patch "/api/v1/accounts/#{account.id}", headers: user.create_new_auth_token,
                                            params: { internal_attributes: { Toybaco::BillingAccess::OWNER_KEY => user.id },
                                                      custom_attributes: { Toybaco::BillingAccess::OWNER_KEY => user.id } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(account.reload.internal_attributes[Toybaco::BillingAccess::OWNER_KEY]).to eq(other_owner)
    expect(account.custom_attributes).not_to have_key(Toybaco::BillingAccess::OWNER_KEY)
    get '/api/v1/profile', headers: user.create_new_auth_token
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(Toybaco::BillingAccess::OWNER_KEY, 'sub_fixture', 'toybaco_contract', 'internal_attributes')
  end

  it '旧Enterprise課金APIも別管理者による迂回を拒否する' do
    account.update!(internal_attributes: account.internal_attributes.merge(Toybaco::BillingAccess::OWNER_KEY => create(:user).id))
    allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(true)
    expect(Enterprise::CreateStripeCustomerJob).not_to receive(:perform_later)
    expect(Enterprise::Billing::CreateSessionService).not_to receive(:new)
    expect(Enterprise::Billing::TopupCheckoutService).not_to receive(:new)
    %w[checkout subscription select_billing_currency toggle_deletion topup_checkout].each do |action|
      post "/enterprise/api/v1/accounts/#{account.id}/#{action}", headers: user.create_new_auth_token,
                                                                  params: { credits: 10, currency: 'usd', action_type: 'delete' }, as: :json
      expect(response).to have_http_status(:forbidden)
    end
    get "/enterprise/api/v1/accounts/#{account.id}/topup_options", headers: user.create_new_auth_token
    expect(response).to have_http_status(:forbidden)
  end

  it '管理者に見積の表示項目と期限付き確認票だけを返し、保存済み契約を変えない' do
    expect(service).to receive(:preview).with(selection, user_id: user.id).and_return(quote)
    change('preview', selection)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['quote']).to include('target_name' => 'スタンダード', 'amount_due' => 4321)
    expect(response.parsed_body['quote']).not_to have_key('internal_field')
    expect(response.parsed_body['confirmation_token']).to be_present
    expect(response.headers['Cache-Control']).to eq('no-store')
    expect(response.body).not_to include('fixture-billing-key')
  end

  it 'サーバーが署名した確認票だけを実行し、改ざんと期限切れを拒否する' do
    verifier = Rails.application.message_verifier('toybaco-plan-change')
    token = verifier.generate(quote, purpose: 'plan-change', expires_in: 10.minutes)
    expect(service).to receive(:commit).once.with(quote, user_id: user.id).and_return('status' => 'payment_pending')
    change('confirm', { confirmation_token: token })
    expect(response.parsed_body).to eq('status' => 'payment_pending')
    change('confirm', { confirmation_token: "#{token}tampered" })
    expect(response).to have_http_status(:conflict)
    expired = verifier.generate(quote, purpose: 'plan-change', expires_at: 1.minute.ago)
    change('confirm', { confirmation_token: expired })
    expect(response).to have_http_status(:conflict)
  end

  it '未ログイン・非所属店舗・不正店舗ID・一般メンバーは全変更操作を実行できない' do
    expect(Toybaco::Checkout::PlanChange).not_to receive(:new)
    %w[preview confirm refresh cancel].each do |action|
      change(action, {}, account_id: create(:account).id)
      expect(response).to have_http_status(:forbidden)
      change(action, {}, account_id: 'invalid')
      expect(response).to have_http_status(:bad_request)
    end
    user.account_users.find_by!(account: account).update!(role: :agent)
    %w[preview confirm refresh cancel].each do |action|
      change(action)
      expect(response).to have_http_status(:forbidden)
    end
    allow(Toybaco::Oidc::SessionReader).to receive(:new).and_return(instance_double(Toybaco::Oidc::SessionReader, user: nil))
    change('preview', selection)
    expect(response).to have_http_status(:unauthorized)
  end

  it 'Origin欠落・別origin・same-site・通常formからは変更できない' do
    expect(service).not_to receive(:preview)
    [{}, headers.merge('Origin' => 'https://attacker.invalid'), headers.merge('Sec-Fetch-Site' => 'same-site')].each do |bad_headers|
      change('preview', selection, origin_headers: bad_headers)
      expect(response).to have_http_status(:forbidden)
    end
    post "/toybaco/billing/change_preview?account_id=#{account.id}", params: selection, headers: headers
    expect(response).to have_http_status(:forbidden)
  end

  it '管理者の状態再確認と予約取消だけを自店舗のサービスへ渡す' do
    expect(Toybaco::Checkout::PlanChange).to receive(:new).with(account: have_attributes(id: account.id), client: anything).twice.and_return(service)
    expect(service).to receive(:refresh).and_return('status' => 'payment_pending')
    change('refresh')
    expect(response.parsed_body).to eq('status' => 'payment_pending')
    expect(service).to receive(:cancel_reservation).with('opaque-receipt-token').and_return('status' => 'released')
    change('cancel', { confirmation_token: 'opaque-receipt-token' })
    expect(response.parsed_body).to eq('status' => 'released')
  end

  it 'Stripe障害や契約競合で秘密情報を返さず、再確認か支払い導線を案内する' do
    allow(service).to receive(:preview).and_raise(Toybaco::Checkout::Error, 'private API diagnostic')
    change('preview', selection)
    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).not_to match(/private|fixture-billing-key/)
    allow(service).to receive(:preview).and_raise(Toybaco::Checkout::PlanChangeError, 'unpaid')
    change('preview', selection)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['message']).to include('未払い', 'お支払い方法・請求履歴')
  end

  describe 'Toybaco専用のお支払いポータル' do
    around do |example|
      original = ENV.fetch('TOYBACO_STRIPE_PORTAL_CONFIGURATION', nil)
      ENV.delete('TOYBACO_STRIPE_PORTAL_CONFIGURATION')
      example.run
    ensure
      if original
        ENV['TOYBACO_STRIPE_PORTAL_CONFIGURATION'] = original
      else
        ENV.delete('TOYBACO_STRIPE_PORTAL_CONFIGURATION')
      end
    end

    it 'サーバー指定の専用configurationと契約のcustomerだけをStripeの実POST引数へ渡す' do
      ENV['TOYBACO_STRIPE_PORTAL_CONFIGURATION'] = 'bpc_ToybacoFixture'
      subscription = stub_request(:get, 'https://api.stripe.com/v1/subscriptions/sub_fixture')
                     .to_return(status: 200, body: { customer: 'cus_owned' }.to_json)
      portal = stub_request(:post, 'https://api.stripe.com/v1/billing_portal/sessions')
               .with(body: { 'configuration' => 'bpc_ToybacoFixture', 'customer' => 'cus_owned',
                             'return_url' => 'https://www.example.com/' })
               .to_return(status: 200, body: { url: 'https://billing.stripe.com/p/session/fixture' }.to_json)
      post "/toybaco/billing/portal?account_id=#{account.id}",
           params: { configuration: 'bpc_Attacker', customer: 'cus_other' }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('url' => 'https://billing.stripe.com/p/session/fixture')
      expect(subscription).to have_been_requested.once
      expect(portal).to have_been_requested.once
    end

    it '専用configurationが未設定・空・不正なら共有defaultへ進まずStripeを一度も呼ばない' do
      expect(Net::HTTP).not_to receive(:start)
      [nil, '', ' ', 'bpc_', 'cs_other', 'bpc_valid/other', "bpc_valid\n"].each do |configuration|
        if configuration
          ENV['TOYBACO_STRIPE_PORTAL_CONFIGURATION'] = configuration
        else
          ENV.delete('TOYBACO_STRIPE_PORTAL_CONFIGURATION')
        end
        post "/toybaco/billing/portal?account_id=#{account.id}", headers: headers, as: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq('error' => 'not_available')
      end
    end

    it '専用configurationがあっても別originや一般メンバーのポータル発行は拒否する' do
      ENV['TOYBACO_STRIPE_PORTAL_CONFIGURATION'] = 'bpc_ToybacoFixture'
      expect(Net::HTTP).not_to receive(:start)
      post "/toybaco/billing/portal?account_id=#{account.id}", headers: headers.merge('Origin' => 'https://other.invalid'), as: :json
      expect(response).to have_http_status(:forbidden)
      user.account_users.find_by!(account: account).update!(role: :agent)
      post "/toybaco/billing/portal?account_id=#{account.id}", headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it '専用configurationが未設定でも既存のプラン変更見積と期間末解約を妨げない' do
      expect(service).to receive(:preview).with(selection, user_id: user.id).and_return(quote)
      change('preview', selection)
      expect(response).to have_http_status(:ok)
      expect(service).to receive(:cancel_subscription).with(reservation_token: 'owned-reservation').and_return('status' => 'cancel_at_period_end')
      post "/toybaco/billing/cancel?account_id=#{account.id}",
           params: { reservation_token: 'owned-reservation' }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('status' => 'cancel_at_period_end')
    end
  end

  context 'with a persisted purchased snapshot' do
    require Rails.root.join('lib/toybaco/agent_seat_limit')

    # PostgreSQL/model/controller/ERB are real; catalog revision and HTTP/session replies are fixtures.
    let(:catalog) { Toybaco::PlanCatalog.default }
    let(:terms) { catalog.sale('pro', 'month') }
    let(:account) { create(:account, name: 'P02 isolated fixture') }
    let(:user) { create(:user, account: account) }
    let(:subscription_id) { 'sub_P02Fixture' }
    let(:price_id) { 'price_P02Original' }
    let(:price) do
      {
        'id' => price_id, 'active' => true, 'livemode' => false, 'currency' => 'jpy',
        'unit_amount' => terms.dig('cycles', 'month', 'amount'),
        'billing_scheme' => 'per_unit', 'tax_behavior' => 'exclusive',
        'metadata' => { 'toybaco_plan' => 'pro', 'toybaco_plan_version' => terms['plan_version'] },
        'recurring' => { 'interval' => 'month', 'interval_count' => 1, 'usage_type' => 'licensed' },
        'product' => { 'id' => 'prod_P02Original', 'active' => true,
                       'name' => terms['product_name'], 'description' => terms['description'] }
      }
    end
    let(:subscription) do
      {
        'id' => subscription_id, 'customer' => 'cus_P02Fixture', 'status' => 'active',
        'livemode' => false, 'collection_method' => 'charge_automatically',
        'cancel_at_period_end' => false, 'schedule' => nil,
        'items' => { 'has_more' => false, 'data' => [{
          'id' => 'si_P02Fixture', 'quantity' => 1,
          'current_period_start' => Time.now.to_i - 3600,
          'current_period_end' => Time.now.to_i + 3600, 'price' => price
        }] },
        'latest_invoice' => {
          'id' => 'in_P02Fixture', 'status' => 'paid', 'currency' => 'jpy',
          'total' => 49_280, 'amount_paid' => 49_280,
          'total_discount_amounts' => [], 'total_tax_amounts' => [{ 'amount' => 4480 }],
          'hosted_invoice_url' => 'https://invoice.stripe.com/i/p02fixture'
        }
      }
    end

    around do |example|
      unless Rails.env.test? && ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
        raise 'P02 candidate requires the isolated test PostgreSQL environment'
      end

      overrides = { 'TOYBACO_STRIPE_KEY' => 'fixture-p02-key', 'TOYBACO_STRIPE_MODE' => 'test',
                    'TOYBACO_STRIPE_PRICE_PRO' => price_id }
      old = overrides.to_h { |key, _value| [key, ENV.fetch(key, nil)] }
      overrides.each { |key, value| ENV[key] = value }
      example.run
    ensure
      old&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end

    before do
      # Restore the real plan-change constructor after the parent request fixture.
      allow(Toybaco::Checkout::PlanChange).to receive(:new).and_call_original
      stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/subscriptions/sub_P02Fixture(?:\?.*)?\z})
        .to_return(status: 200, body: subscription.to_json, headers: { 'Content-Type' => 'application/json' })
      stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/prices/price_P02Original(?:\?.*)?\z})
        .to_return(status: 200, body: price.to_json, headers: { 'Content-Type' => 'application/json' })
      # No Checkout client, synchronizer, controller, model or view double.
      snapshot = Toybaco::Entitlements.snapshot_for(terms, cycle: 'month')
      Toybaco::Entitlements.apply!(account, snapshot, subscription_id: subscription_id)
    end

    def stored_account
      Account.uncached { Account.find(account.id) }
    end

    def synchronize(selected_catalog)
      client = Toybaco::Checkout::Client.new('fixture-p02-key')
      sync = Toybaco::SubscriptionSync.new(client: client, catalog: selected_catalog)
      sync.call(stored_account, subscription_id: subscription_id)
    end

    def billing_document
      get '/toybaco/billing', params: { account_id: account.id }
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/html')
      expect(response.headers['Cache-Control']).to eq('no-store')
      Nokogiri::HTML(response.body)
    end

    def presentation(document)
      cards = document.css('#billing-content > .card')
      {
        name: document.at_css('.plan-name').text.strip,
        prices: document.css('.plan-price').map { |node| node.text.gsub(/\s+/, ' ').strip },
        invoice_rows: cards.first.css('.row').map { |node| node.text.gsub(/\s+/, ' ').strip },
        features: cards[1].css('.row').map { |node| node.text.gsub(/\s+/, ' ').strip }
      }
    end

    def revised_pro_terms
      revised = Marshal.load(Marshal.dump(catalog.data['plans']['pro']['versions'].fetch(terms['plan_version'])))
      revised['name'] = 'P02 revised sales fixture'
      revised['cycles']['month']['amount'] = 98_900
      revised['entitlements']['features'].merge!('posting' => false, 'channel_instagram' => false)
      revised['entitlements']['limits'].merge!('agents' => 1, 'ai_replies' => 1)
      revised
    end

    def future_catalog
      data = Marshal.load(Marshal.dump(catalog.data))
      data['plans']['pro']['versions']['p02-future-v2'] = revised_pro_terms
      data['current_versions']['pro'] = 'p02-future-v2'
      Toybaco::PlanCatalog.new(data)
    end

    def expect_purchased_presentation(before)
      expect(before[:name]).to eq('プロ プラン')
      expect(before[:prices].join).to include('44,800')
      expect(before[:invoice_rows].join).to include('49,280', '4,480')
      expect(before[:features].join).to include('SNS 予約投稿', '利用中', '月500件')
    end

    def expect_revised_sales(revised, original_version)
      expect(Toybaco::PlanCatalog.default.sale('pro', 'month')).to include('plan_version' => 'p02-future-v2')
      expect(revised.sale('pro', 'month').dig('cycles', 'month', 'amount')).to eq(98_900)
      expect(revised.sale('pro', 'month').dig('entitlements', 'limits')).to include('agents' => 1, 'ai_replies' => 1)
      expect(revised.sale('pro', 'month').dig('entitlements', 'features', 'posting')).to be(false)
      expect { revised.sale('pro', 'month', version: original_version) }.to raise_error(Toybaco::PlanCatalog::Invalid)
    end

    def expect_purchased_state(after_account, original_attributes, original_flags, original_contract)
      expect(after_account.internal_attributes).to eq(original_attributes)
      expect(after_account.feature_flags).to eq(original_flags)
      expect(Toybaco::Entitlements.contract_for(after_account)).to eq(original_contract)
      expect(Toybaco::AgentSeatLimit.limit_for(after_account)).to be_nil
    end

    it '保存した旧版契約の料金・機能・請求HTMLを、新規販売版改定と再同期後も保持する' do
      expect(synchronize(catalog)).to eq('applied')
      before_account = stored_account
      original_attributes = before_account.internal_attributes.deep_dup
      original_flags = before_account.feature_flags
      original_contract = original_attributes.fetch('toybaco_contract')
      before = presentation(billing_document)
      expect_purchased_presentation(before)

      revised = future_catalog
      allow(Toybaco::PlanCatalog).to receive(:default).and_return(revised)
      expect_revised_sales(revised, original_contract['plan_version'])

      2.times { expect(synchronize(revised)).to eq('applied') }
      after_account = stored_account
      expect_purchased_state(after_account, original_attributes, original_flags, original_contract)
      expect(presentation(billing_document)).to eq(before)
      expect(a_request(:post, %r{\Ahttps://api\.stripe\.com/})).not_to have_been_made
    end
  end
end
