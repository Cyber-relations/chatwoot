# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Stripe signed webhook body', type: :request do
  let(:secret) { 'whsec_synthetic000000000000000000000000' }
  let(:timestamp) { Time.current.to_i }
  let(:payload) do
    { id: 'evt_Body', object: 'event', created: timestamp, livemode: false,
      type: 'charge.refunded', data: { object: { id: 'ch_Body' } } }
  end
  let(:body) { payload.to_json }
  let(:query) { { id: 'evt_Query', type: 'customer.subscription.deleted', data: { object: { id: 'sub_Query' } } }.to_query }
  let(:headers) do
    signature = OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{body}")
    { 'CONTENT_TYPE' => 'application/json', 'Stripe-Signature' => "t=#{timestamp},v1=#{signature}" }
  end

  around do |example|
    with_modified_env('STRIPE_WEBHOOK_SECRET' => secret, 'TOYBACO_STRIPE_PACK_WEBHOOK_SECRET' => secret,
                      'TOYBACO_STRIPE_BILLING_WEBHOOK_SECRET' => secret, 'TOYBACO_STRIPE_MODE' => 'test',
                      'TOYBACO_BILLING_INGRESS_ENABLED' => 'true') { example.run }
  end

  shared_examples 'body-bound Stripe dispatch' do
    [false, true].each do |query_present|
      it "dispatches the signed body with query #{query_present ? 'present' : 'absent'}" do
        post "#{endpoint}#{query_present ? "?#{query}" : ''}", params: body, headers: headers

        expect(response).to have_http_status(:ok)
        expect_body_dispatch
      end
    end

    it 'rejects a changed signature before dispatch' do
      post "#{endpoint}?#{query}", params: body, headers: headers.merge('Stripe-Signature' => "t=#{timestamp},v1=#{'0' * 64}")

      expect(response).to have_http_status(:bad_request)
      expect_no_dispatch
    end
  end

  context 'with Enterprise billing' do
    let(:endpoint) { '/enterprise/webhooks/stripe' }
    let(:service) { instance_double(Enterprise::Billing::HandleStripeEventService, perform: nil) }

    before { allow(Enterprise::Billing::HandleStripeEventService).to receive(:new).and_return(service) }

    def expect_body_dispatch
      expect(service).to have_received(:perform).once do |arguments|
        expect(arguments.fetch(:event).to_hash.deep_stringify_keys).to eq(JSON.parse(body))
      end
    end

    def expect_no_dispatch
      expect(service).not_to have_received(:perform)
    end

    it_behaves_like 'body-bound Stripe dispatch'

    [nil, '', " \t\n"].each do |blank_secret|
      it "rejects a blank Enterprise signing secret #{blank_secret.inspect} before verification or dispatch" do
        forged = OpenSSL::HMAC.hexdigest('SHA256', blank_secret.to_s, "#{timestamp}.#{body}")
        request_headers = headers.merge('Stripe-Signature' => "t=#{timestamp},v1=#{forged}")
        expect(Stripe::Webhook).not_to receive(:construct_event)

        with_modified_env('STRIPE_WEBHOOK_SECRET' => blank_secret) do
          post endpoint, params: body, headers: request_headers
        end

        expect(response).to have_http_status(:bad_request)
        expect_no_dispatch
      end
    end
  end

  context 'with Toybaco pack payments' do
    let(:endpoint) { '/toybaco/webhooks/stripe/packs' }

    before { allow(Toybaco::Growth::PaymentReceipt).to receive(:accept!) }

    def expect_body_dispatch
      snapshot = {
        'id' => 'evt_Body', 'object' => 'event', 'created' => timestamp, 'livemode' => false,
        'type' => 'charge.refunded', 'data' => { 'object' => { 'id' => 'ch_Body', 'charge' => 'ch_Body' } }
      }
      expect(Toybaco::Growth::PaymentReceipt).to have_received(:accept!)
        .with({ action: 'pack_refund', event_id: 'evt_Body', reference_id: 'ch_Body', snapshot: snapshot }).once
    end

    def expect_no_dispatch
      expect(Toybaco::Growth::PaymentReceipt).not_to have_received(:accept!)
    end

    it_behaves_like 'body-bound Stripe dispatch'
  end

  context 'with Toybaco billing' do
    let(:endpoint) { '/toybaco/webhooks/stripe/billing' }
    let(:receipt) { instance_double(Toybaco::BillingEvent, id: 1, event_id: 'evt_Body', mode: 'test') }
    let(:payload) do
      super().merge(type: 'customer.subscription.updated', data: { object: { id: 'sub_Body', object: 'subscription' } })
    end

    before do
      allow(Toybaco::Growth::BillingReceipt).to receive(:accept!).and_return(receipt)
      allow(Toybaco::Growth::BillingReceipt).to receive(:enqueue)
    end

    def expect_body_dispatch
      expect(Toybaco::Growth::BillingReceipt).to have_received(:accept!)
        .with(hash_including(event_id: 'evt_Body', reference_id: 'sub_Body', mode: 'test')).once
      expect(Toybaco::Growth::BillingReceipt).to have_received(:enqueue).with(receipt).once
    end

    def expect_no_dispatch
      expect(Toybaco::Growth::BillingReceipt).not_to have_received(:accept!)
      expect(Toybaco::Growth::BillingReceipt).not_to have_received(:enqueue)
    end

    it_behaves_like 'body-bound Stripe dispatch'
  end
end
