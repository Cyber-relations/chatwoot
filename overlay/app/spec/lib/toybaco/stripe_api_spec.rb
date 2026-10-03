# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/toybaco/checkout')

RSpec.describe Toybaco::StripeApi do
  let(:pinned) { { 'Stripe-Version' => described_class::VERSION } }
  let(:client) { Toybaco::Checkout::Client.new('fixture-stripe-key') }

  it '固定する版はStripeの版の形式(日付.リリース名)で、Stripe-Versionヘッダーで送る' do
    expect(described_class::VERSION).to match(/\A\d{4}-\d{2}-\d{2}\.[a-z]+\z/)
    expect(described_class::VERSION).to be_frozen
    expect(described_class::HEADER).to eq('Stripe-Version')
    ['', '2026-06-24', '2026-06-24.', '2026-06-24.Dahlia', "2026-06-24.dahlia\n", ' 2026-06-24.dahlia'].each do |invalid|
      expect(invalid).not_to match(described_class::VERSION_FORMAT)
    end
  end

  it 'Checkout::ClientはGET・POST・DELETEのどの要求にも固定した版を付け、認証と冪等キーを保つ' do
    retrieve = stub_request(:get, 'https://api.stripe.com/v1/events/evt_fixture')
               .with(headers: pinned, basic_auth: ['fixture-stripe-key', ''])
               .to_return(status: 200, body: { id: 'evt_fixture' }.to_json)
    create = stub_request(:post, 'https://api.stripe.com/v1/checkout/sessions')
             .with(headers: pinned.merge('Idempotency-Key' => 'fixture-idempotency'), body: { 'mode' => 'subscription' })
             .to_return(status: 200, body: { id: 'cs_test_fixture' }.to_json)
    cancel = stub_request(:delete, 'https://api.stripe.com/v1/subscriptions/sub_fixture')
             .with(headers: pinned)
             .to_return(status: 200, body: { id: 'sub_fixture', status: 'canceled' }.to_json)

    expect(client.retrieve_event('evt_fixture')).to eq('id' => 'evt_fixture')
    expect(client.create_checkout_session({ 'mode' => 'subscription' }, idempotency_key: 'fixture-idempotency'))
      .to eq('id' => 'cs_test_fixture')
    expect(client.cancel_unpaid_subscription('sub_fixture')).to include('status' => 'canceled')
    expect(retrieve).to have_been_requested.once
    expect(create).to have_been_requested.once
    expect(cancel).to have_been_requested.once
  end
end
