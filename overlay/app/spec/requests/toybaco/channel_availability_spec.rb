# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::ChannelAvailability, type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:headers) { { 'api_access_token' => user.access_token.token } }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TOYBACO_TWITTER_ENABLED').and_return(nil)
    allow(Twitty::Facade).to receive(:new).and_raise('unexpected provider access')
  end

  %w[twitter twitter_profile].each do |type|
    it "rejects #{type} inbox creation through the account API" do
      expect do
        post "/api/v1/accounts/#{account.id}/inboxes", params: { name: 'fixture', channel: { type: type } }, headers: headers
      end.not_to change(Inbox, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq('error' => described_class.error)
      expect(Channel::TwitterProfile.count).to eq(0)
    end
  end

  it 'rejects OAuth authorization before contacting Twitter' do
    post "/api/v1/accounts/#{account.id}/twitter/authorization", headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to eq('success' => false, 'error' => described_class.error)
    expect(Twitty::Facade).not_to have_received(:new)
  end

  [true, false].each do |validate|
    it "blocks model/service creation with validate=#{validate}" do
      channel = build(:channel_twitter_profile)

      expect(channel.save(validate: validate)).to be(false)
      expect(channel.errors[:base]).to include(described_class.error)
      expect(channel).not_to be_persisted
    end

    it "blocks attaching an existing Twitter channel to a new inbox with validate=#{validate}" do
      allow(ENV).to receive(:[]).with('TOYBACO_TWITTER_ENABLED').and_return('true')
      channel = create(:channel_twitter_profile)
      allow(ENV).to receive(:[]).with('TOYBACO_TWITTER_ENABLED').and_return(nil)
      inbox = build(:inbox, channel: channel, account: channel.account)

      expect(inbox.save(validate: validate)).to be(false)
      expect(inbox.errors[:base]).to include(described_class.error)
      expect(inbox).not_to be_persisted
    end
  end

  it 'blocks account association creation' do
    expect do
      account.twitter_profiles.create!(profile_id: 'fixture', twitter_access_token: 'fixture', twitter_access_token_secret: 'fixture')
    end.to raise_error(ActiveRecord::RecordInvalid)
  end
end
