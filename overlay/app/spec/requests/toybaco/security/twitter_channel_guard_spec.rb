# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::Security::TwitterChannelGuard, type: :request do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TOYBACO_TWITTER_ENABLED').and_return(nil)
    allow(Rails.logger).to receive(:warn)
    allow(Twitty::Facade).to receive(:new).and_raise('unexpected provider access')
    allow(Resolv).to receive(:getaddresses).and_raise('unexpected DNS lookup')
    allow(Socket).to receive(:tcp).and_raise('unexpected TCP connection')
    allow(TCPSocket).to receive(:new).and_raise('unexpected TCP connection')
    allow(TCPSocket).to receive(:open).and_raise('unexpected TCP connection')
  end

  it 'rejects unsigned events targeting an existing Twitter inbox before consuming them' do
    allow(ENV).to receive(:[]).with('TOYBACO_TWITTER_ENABLED').and_return('true')
    channel = create(:channel_twitter_profile)
    create(:inbox, channel: channel, account: channel.account)
    allow(ENV).to receive(:[]).with('TOYBACO_TWITTER_ENABLED').and_return(nil)
    expect(Webhooks::Twitter).not_to receive(:new)
    expect(Channel::TwitterProfile).not_to receive(:find_by)

    expect do
      post '/webhooks/twitter', params: { for_user_id: channel.profile_id, direct_message_events: [{ private: 'fixture' }] }
    end.not_to change(Message, :count)

    expect(response).to have_http_status(:not_found)
    expect(Rails.logger).to have_received(:warn).with('Toybaco webhook rejected: twitter channel is not offered').once
  end

  it 'rejects CRC verification before constructing a provider client' do
    get '/webhooks/twitter', params: { crc_token: 'private fixture' }

    expect(response).to have_http_status(:not_found)
    expect(Twitty::Facade).not_to have_received(:new)
    expect(Rails.logger).to have_received(:warn).with('Toybaco webhook rejected: twitter channel is not offered').once
  end

  it 'rejects OAuth callbacks before Redis lookup, token exchange or channel creation' do
    expect(Redis::Alfred).not_to receive(:get)
    expect(Twitter::WebhookSubscribeService).not_to receive(:new)

    expect do
      get '/twitter/callback', params: { oauth_token: 'private fixture', oauth_verifier: 'fixture' }
    end.not_to change(Channel::TwitterProfile, :count)

    expect(response).to have_http_status(:not_found)
    expect(Twitty::Facade).not_to have_received(:new)
  end
end
