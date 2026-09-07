# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/toybaco/store_fulfillment')

RSpec.describe 'Toybaco purchased store billing', type: :request do
  let(:parent) { create(:account, name: 'Private parent name', internal_attributes: { 'toybaco_subscription_id' => 'sub_parent' }) }
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:contract) { Toybaco::Entitlements.snapshot_for(Toybaco::PlanCatalog.default.sale('light', 'month'), cycle: 'month') }

  before do
    reader = instance_double(Toybaco::Oidc::SessionReader, user: user)
    allow(Toybaco::Oidc::SessionReader).to receive(:new).and_return(reader)
    user.account_users.find_by!(account: account).update!(role: :administrator)
    Toybaco::Entitlements.apply!(account, contract)
  end

  def link_purchase
    addon = Toybaco::Entitlements.new_addon('opt-store', quantity: 1, source: 'stripe')
    purchase = { addon: addon, item: { 'id' => 'si_store', 'price' => { 'id' => 'price_store', 'unit_amount' => 9800 } }, contract: contract }
    binding = Toybaco::StoreFulfillment.purchase_binding(parent, account, { administrator_id: user.id }, purchase)
    account.update!(internal_attributes: account.internal_attributes.merge(Toybaco::StoreFulfillment::PURCHASE => binding))
    parent.update!(internal_attributes: parent.internal_attributes.merge(Toybaco::StoreFulfillment::REGISTRY => { 'si_store:1' => binding }))
  end

  it '親に所属しない子管理者にも保存版と購入元管理の案内だけを表示する' do
    link_purchase
    expect(Toybaco::Checkout::Client).not_to receive(:new)
    get "/toybaco/billing?account_id=#{account.id}"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('ライト', '保存した契約版: 2026-09-06.1', '購入元の追加店舗オプション', '購入元の契約で管理')
    expect(response.body).not_to include('請求書払い', 'Private parent name', 'sub_parent', 'id="portal"', 'id="cancel-box"')
  end

  it '通常の個別契約には従来の案内を維持する' do
    get "/toybaco/billing?account_id=#{account.id}"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('請求書払い(または個別契約)')
    expect(response.body).not_to include('購入元の追加店舗オプション')
  end

  it '壊れた片側対応から追加店舗の開通を断定しない' do
    link_purchase
    parent.update!(internal_attributes: parent.internal_attributes.except(Toybaco::StoreFulfillment::REGISTRY))
    get "/toybaco/billing?account_id=#{account.id}"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('購入元の追加店舗オプション')
  end
end
