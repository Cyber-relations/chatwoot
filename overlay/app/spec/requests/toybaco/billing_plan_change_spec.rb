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
    allow(Toybaco::Checkout::PlanChange).to receive(:new).and_return(service)
  end

  def change(action, params = {}, account_id: account.id, origin_headers: headers)
    post "/toybaco/billing/change_#{action}?account_id=#{account_id}", params: params, headers: origin_headers, as: :json
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
end
