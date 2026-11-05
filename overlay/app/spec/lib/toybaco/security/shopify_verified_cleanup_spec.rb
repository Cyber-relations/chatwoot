# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::Security::ShopifyVerifiedCleanup do
  let!(:hook) { create(:integrations_hook, :shopify, access_token: 'old-token') }
  let(:url) { "https://#{hook.reference_id}/admin/oauth/access_scopes.json" }

  it 'reloads the persisted token under the lock instead of verifying a stale instance' do
    Integrations::Hook.find(hook.id).update!(access_token: 'current-token')
    request = stub_request(:get, url).with(headers: { 'X-Shopify-Access-Token' => 'current-token' }).to_return(status: 200)

    described_class.new(hook).perform

    expect(request).to have_been_requested.once
    expect(hook.reload.access_token).to eq('current-token')
  end

  it 'does nothing if another request deleted the hook before the locked lookup' do
    Integrations::Hook.find(hook.id).destroy!
    expect(Net::HTTP).not_to receive(:new)

    described_class.new(hook).perform

    expect(Integrations::Hook.exists?(hook.id)).to be(false)
  end

  it 'leaves state unchanged on a network error and permits a later verified retry' do
    request = stub_request(:get, url).to_timeout.then.to_return(status: 401)

    expect { described_class.new(hook).perform }.to raise_error(Toybaco::Security::ShopifyInstallationStatus::Unavailable)
    expect(hook.reload.access_token).to eq('old-token')

    described_class.new(hook).perform

    expect(request).to have_been_requested.twice
    expect(Integrations::Hook.exists?(hook.id)).to be(false)
  end
end
