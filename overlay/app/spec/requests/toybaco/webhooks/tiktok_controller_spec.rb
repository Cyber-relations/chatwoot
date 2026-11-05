# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::TiktokController, type: :request do
  let(:secret) { 'synthetic-tiktok-secret' }
  let(:configured_secret) { secret }
  let(:body) { { event: 'im_receive_msg', user_openid: 'fixture' }.to_json }
  let(:timestamp) { Time.current.to_i }
  let(:signing_secret) { secret }
  let(:signature) { OpenSSL::HMAC.hexdigest('SHA256', signing_secret, "#{timestamp}.#{body}") }
  let(:headers) do
    { 'CONTENT_TYPE' => 'application/json', 'Tiktok-Signature' => "t=#{timestamp},s=#{signature}" }
  end

  around do |example|
    with_modified_env('TIKTOK_APP_SECRET' => secret) { example.run }
  end

  before do
    # Exercise the actual database/cache/ENV loader, including an existing blank row.
    InstallationConfig.find_or_initialize_by(name: 'TIKTOK_APP_SECRET').update!(value: configured_secret, locked: false)
    GlobalConfig.clear_cache
    allow(Webhooks::TiktokEventsJob).to receive(:perform_later)
  end

  after { GlobalConfig.clear_cache }

  [nil, '', " \t\n"].each do |blank_secret|
    context "with a blank database secret #{blank_secret.inspect} and populated ENV" do
      let(:configured_secret) { blank_secret }
      let(:signing_secret) { blank_secret.to_s }

      it 'rejects before HMAC verification or enqueueing' do
        expect(GlobalConfigService.load('TIKTOK_APP_SECRET', nil)).to eq(blank_secret)
        request_headers = headers
        expect(OpenSSL::HMAC).not_to receive(:hexdigest)
        expect(Webhooks::TiktokEventsJob).not_to receive(:set)

        post '/webhooks/tiktok', params: body, headers: request_headers

        expect(response).to have_http_status(:unauthorized)
        expect(Webhooks::TiktokEventsJob).not_to have_received(:perform_later)
      end
    end
  end

  it 'accepts a valid signature using the real configured secret' do
    post '/webhooks/tiktok', params: body, headers: headers

    expect(response).to have_http_status(:ok)
    expect(Webhooks::TiktokEventsJob).to have_received(:perform_later).with(JSON.parse(body)).once
  end

  it 'rejects an empty-key signature when a real secret is configured' do
    forged_signature = OpenSSL::HMAC.hexdigest('SHA256', '', "#{timestamp}.#{body}")
    forged_headers = headers.merge('Tiktok-Signature' => "t=#{timestamp},s=#{forged_signature}")
    post '/webhooks/tiktok', params: body, headers: forged_headers

    expect(response).to have_http_status(:unauthorized)
    expect(Webhooks::TiktokEventsJob).not_to have_received(:perform_later)
  end

  it 'ignores a query echo event for a signed incoming event' do
    expect(Webhooks::TiktokEventsJob).not_to receive(:set)

    post '/webhooks/tiktok?event=im_send_msg&user_openid=query-user', params: body, headers: headers

    expect(response).to have_http_status(:ok)
    expect(Webhooks::TiktokEventsJob).to have_received(:perform_later).with(JSON.parse(body)).once
  end

  context 'with a signed echo event' do
    let(:body) { { event: 'im_send_msg', user_openid: 'fixture' }.to_json }

    it 'retains the echo delay despite a conflicting query event' do
      delayed_job = instance_double(ActiveJob::ConfiguredJob, perform_later: nil)
      expect(Webhooks::TiktokEventsJob).to receive(:set).with(wait: 2.seconds).and_return(delayed_job)

      post '/webhooks/tiktok?event=im_receive_msg', params: body, headers: headers

      expect(response).to have_http_status(:ok)
      expect(delayed_job).to have_received(:perform_later).with(JSON.parse(body)).once
      expect(Webhooks::TiktokEventsJob).not_to have_received(:perform_later)
    end
  end

  it 'retains the real ENV migration when no database row exists' do
    InstallationConfig.find_by!(name: 'TIKTOK_APP_SECRET').destroy!
    GlobalConfig.clear_cache

    post '/webhooks/tiktok', params: body, headers: headers

    expect(response).to have_http_status(:ok)
    expect(Webhooks::TiktokEventsJob).to have_received(:perform_later).with(JSON.parse(body)).once
  end
end
