# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/toybaco/store_fulfillment')

RSpec.describe 'Toybaco purchased store billing', type: :request do
  let(:parent) { create(:account, name: 'Private parent name', internal_attributes: { 'toybaco_subscription_id' => 'sub_parent' }) }
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:owner) { create(:user, account: parent) }
  let(:contract) { Toybaco::Entitlements.snapshot_for(Toybaco::PlanCatalog.default.sale('light', 'month'), cycle: 'month') }

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
end
