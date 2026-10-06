# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/toybaco/store_fulfillment')
require Rails.root.join('lib/toybaco/checkout/plan_change')

RSpec.describe 'Toybaco purchased store billing', type: :request do
  let(:parent) { create(:account, name: 'Private parent name', internal_attributes: { 'toybaco_subscription_id' => 'sub_parent' }) }
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:owner) { create(:user, account: parent) }
  let(:contract) { Toybaco::Entitlements.snapshot_for(Toybaco::PlanCatalog.default.definition('light', '2026-09-06.1'), cycle: 'month') }

  before do
    reader = instance_double(Toybaco::Oidc::SessionReader, user: user)
    allow(Toybaco::Oidc::SessionReader).to receive(:new).and_return(reader)
    user.account_users.find_by!(account: account).update!(role: :administrator)
    Toybaco::Entitlements.apply!(account, contract)
    account.update!(internal_attributes: account.internal_attributes.merge(Toybaco::BillingAccess::OWNER_KEY => user.id))
    parent.update!(internal_attributes: parent.internal_attributes.merge(Toybaco::BillingAccess::OWNER_KEY => owner.id))
  end

  def link_purchase
    addon = Toybaco::Entitlements.new_addon('opt-store', quantity: 1, source: 'stripe')
    purchase = { addon: addon, item: { 'id' => 'si_store', 'price' => { 'id' => 'price_store', 'unit_amount' => 9800 } }, contract: contract }
    binding = Toybaco::StoreFulfillment.purchase_binding(parent, account, { administrator_id: user.id }, purchase)
    attrs = account.internal_attributes.except(Toybaco::BillingAccess::OWNER_KEY)
    account.update!(internal_attributes: attrs.merge(Toybaco::StoreFulfillment::PURCHASE => binding))
    parent.update!(internal_attributes: parent.internal_attributes.merge(Toybaco::StoreFulfillment::REGISTRY => { 'si_store:1' => binding }))
  end

  it '追加店舗の開通担当を契約者とみなさず契約画面と全操作を拒否する' do
    link_purchase
    expect(Toybaco::Checkout::Client).not_to receive(:new)
    get "/toybaco/billing?account_id=#{account.id}"
    expect(response).to have_http_status(:forbidden)
    %w[portal cancel change_preview change_confirm change_refresh change_cancel].each do |action|
      post "/toybaco/billing/#{action}?account_id=#{account.id}", params: {},
                                                                  headers: { 'Origin' => 'http://www.example.com' }, as: :json
      expect(response).to have_http_status(:forbidden)
    end
    get "/toybaco/billing/access?account_id=#{account.id}"
    expect(response.parsed_body).to eq('can_view_billing' => false, 'can_manage_billing' => false)
  end

  it '通常の個別契約には従来の案内を維持する' do
    get "/toybaco/billing?account_id=#{account.id}"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('請求書払い(または個別契約)')
    expect(response.body).not_to include('購入元の追加店舗オプション')
  end

  it '壊れた片側対応では親契約者も子店舗の契約画面を閲覧できない' do
    link_purchase
    sign_in_parent_owner
    parent.update!(internal_attributes: parent.internal_attributes.except(Toybaco::StoreFulfillment::REGISTRY))
    get "/toybaco/billing?account_id=#{account.id}"
    expect(response).to have_http_status(:forbidden)
  end

  def sign_in_parent_owner(role: :administrator)
    create(:account_user, account: account, user: owner, role: role)
    allow(Toybaco::Oidc::SessionReader).to receive(:new).and_return(instance_double(Toybaco::Oidc::SessionReader, user: owner))
  end

  it '親契約者にも子店舗の既存所属が必要で自動追加しない' do
    link_purchase
    allow(Toybaco::Oidc::SessionReader).to receive(:new).and_return(instance_double(Toybaco::Oidc::SessionReader, user: owner))
    get "/toybaco/billing?account_id=#{account.id}"
    expect(response).to have_http_status(:forbidden)
    expect(account.account_users.exists?(user_id: owner.id)).to be(false)
  end

  it '相互に一致した購入対応と既存所属のある親契約者だけが子の保存版を閲覧できる' do
    link_purchase
    sign_in_parent_owner(role: :agent)
    expect(Toybaco::Checkout::Client).not_to receive(:new)
    get "/toybaco/billing?account_id=#{account.id}"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('ライト', '保存した契約版: 2026-09-06.1', '購入元の契約で管理')
    expect(response.body).not_to include('Private parent name', 'sub_parent', 'id="portal"', 'id="cancel-box"')
    get "/toybaco/billing/access?account_id=#{account.id}"
    expect(response.parsed_body).to eq('can_view_billing' => true, 'can_manage_billing' => false)
    expect(account.reload.internal_attributes).not_to have_key(Toybaco::BillingAccess::OWNER_KEY)
    expect(account.account_users.find_by!(user_id: owner.id).role).to eq('agent')
  end

  it '子に矛盾するownerがある場合と親のowner未設定を拒否する' do
    link_purchase
    sign_in_parent_owner
    account.update!(internal_attributes: account.internal_attributes.merge(Toybaco::BillingAccess::OWNER_KEY => user.id))
    get "/toybaco/billing?account_id=#{account.id}"
    expect(response).to have_http_status(:forbidden)
    account.update!(internal_attributes: account.internal_attributes.except(Toybaco::BillingAccess::OWNER_KEY))
    parent.update!(internal_attributes: parent.internal_attributes.except(Toybaco::BillingAccess::OWNER_KEY))
    get "/toybaco/billing?account_id=#{account.id}"
    expect(response).to have_http_status(:forbidden)
  end

  it '別の子店舗へコピーされた購入対応から契約者権限を導かない' do
    link_purchase
    other = create(:account, internal_attributes: account.internal_attributes.deep_dup)
    create(:account_user, account: other, user: owner, role: :administrator)
    allow(Toybaco::Oidc::SessionReader).to receive(:new).and_return(instance_double(Toybaco::Oidc::SessionReader, user: owner))
    get "/toybaco/billing?account_id=#{other.id}"
    expect(response).to have_http_status(:forbidden)
  end

  # 期間末に無料プランへ移る案内は、自動 Free 移行の対象の契約(PeriodEndCancel.paid_contract?)だけに出す。
  describe '解約の案内' do
    let(:free_done) { '解約を受け付けました。現在の契約期間末に無料プランへ移ります。' }
    let(:stop_copy) { 'お申し出以降、次回分の請求は発生しません。日割りの返金はありません。' }

    around do |example|
      saved = %w[TOYBACO_STRIPE_KEY TOYBACO_GROWTH_RETENTION_ENABLED].index_with { |key| ENV.fetch(key, nil) }
      ENV['TOYBACO_STRIPE_KEY'] = 'fixture-billing-key'
      ENV['TOYBACO_GROWTH_RETENTION_ENABLED'] = 'true'
      example.run
    ensure
      saved.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    end

    before do
      allow(Toybaco::Checkout::Client).to receive(:new).and_return(instance_double(Toybaco::Checkout::Client, retrieve_subscription: {}))
      allow(Toybaco::BillingSubscription).to receive(:summarize).and_return(status: 'active', status_label: '有効', cancel_at_period_end: false,
                                                                            items: [], invoice: nil)
      allow(Toybaco::Checkout::PlanChange).to receive(:new).and_return(instance_double(Toybaco::Checkout::PlanChange, state: nil))
    end

    def cancel_texts(version, addons: [], plan_version: nil)
      terms = Toybaco::PlanCatalog.default.definition('standard', version)
      contract = Toybaco::Entitlements.snapshot_for(terms, cycle: 'month', addons: addons)
      contract = contract.merge('plan_version' => plan_version) if plan_version
      Toybaco::Entitlements.apply!(account, contract, subscription_id: 'sub_cancelcopy')
      get "/toybaco/billing?account_id=#{account.id}"
      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)
      { done: document.at_css('#cancel-done-message').text,
        dialog: document.css('#cancel-dialog .dlg-body').reject { |node| node['id'] == 'cancel-reservation-note' }.map(&:text),
        retention: response.body.include?('無料プランで継続する接続') }
    end

    it '追加契約の無い新料金の契約には期間末に無料プランへ移る案内を出す' do
      texts = cancel_texts('2026-09-25.1')
      expect(texts[:done]).to eq(free_done)
      expect(texts[:dialog]).to contain_exactly(a_string_including('現在の契約期間末に無料プランへ移り'))
      expect(texts[:retention]).to be(true)
    end

    it '新料金でも追加契約のある契約には従来の停止の案内を出し、継続する接続の入口を出さない' do
      addon = Toybaco::Entitlements.new_addon('manual-posting', quantity: 1, source: 'manual')
      expect(cancel_texts('2026-09-25.1', addons: [addon])).to eq(done: stop_copy, dialog: [stop_copy], retention: false)
      expect(response.body).to include('AIアシスタント（返信・投稿で共通）')
    end

    it '現行の利用枠のまま版だけが新料金と違う契約には従来の停止の案内を出し、継続する接続の入口を出さない' do
      expect(cancel_texts('2026-09-25.1', plan_version: '2026-09-25.0')).to eq(done: stop_copy, dialog: [stop_copy], retention: false)
      expect(Toybaco::Entitlements.contract_for(account).values_at('plan_version', 'addons')).to eq(['2026-09-25.0', []])
      expect(response.body).to include('AIアシスタント（返信・投稿で共通）')
    end

    it '旧版の契約には従来の停止の案内を出す' do
      expect(cancel_texts('2026-09-06.1')).to eq(done: stop_copy, dialog: [stop_copy], retention: false)
    end

    # SPA の「ご契約内容」の iframe は親のテーマを theme で渡す。dark / light 以外(未指定を含む)は OS の設定に従う。
    it 'iframe から渡されたテーマを画面と iframe の中の導線に写し、それ以外は OS の設定に従う' do
      terms = Toybaco::PlanCatalog.default.definition('standard', '2026-09-25.1')
      Toybaco::Entitlements.apply!(account, Toybaco::Entitlements.snapshot_for(terms, cycle: 'month'), subscription_id: 'sub_theme')
      [%w[dark dark], %w[light light], %w[system system], %w[sepia system], [nil, 'system']].each do |given, expected|
        get '/toybaco/billing', params: { account_id: account.id, theme: given }.compact
        expect(response).to have_http_status(:ok)
        document = Nokogiri::HTML(response.body)
        expect(document.at_css('html')['data-toybaco-theme']).to eq(expected)
        theme = expected == 'system' ? '' : "&theme=#{expected}"
        expect(document.at_css('a[href^="/toybaco/growth/retention"]')['href'])
          .to eq("/toybaco/growth/retention?account_id=#{account.id}#{theme}&target=free")
      end
      get "/toybaco/billing?account_id=#{account.id}&theme[]=dark"
      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).at_css('html')['data-toybaco-theme']).to eq('system')
    end
  end
end
