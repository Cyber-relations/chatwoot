# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RoomChannel, type: :channel do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:credentials) { user.create_new_auth_token }
  let(:request) do
    instance_double(ActionDispatch::Request, cookies: { 'cw_d_session_info' => credentials.to_json },
                                             headers: { 'Origin' => 'https://app.example.test' }, base_url: 'https://app.example.test')
  end

  before do
    stub_connection(request: request)
    connection.define_singleton_method(:close) { |**_options| nil }
  end

  it 'subscribes a logged-in user and closes the socket after server revocation' do
    subscribe(user_id: user.id, account_id: account.id, pubsub_token: user.pubsub_token)
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from("account_#{account.id}")
    user.update!(tokens: {})
    expect(connection).to receive(:close).with(reconnect: false)
    expect(subscription.send(:verify_toybaco_session)).to be(false)
    expect(subscription.send(:streams)).to be_empty
  end

  it 'rejects a user subscription with only the long-lived pubsub identifier' do
    allow(request).to receive(:cookies).and_return({})
    subscribe(user_id: user.id, account_id: account.id, pubsub_token: user.pubsub_token)
    expect(subscription).to be_rejected
    expect(subscription.send(:streams)).to be_empty
  end

  it 'keeps the public contact widget on its separate contact-inbox boundary' do
    contact_inbox = create(:contact_inbox)
    subscribe(pubsub_token: contact_inbox.pubsub_token)
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from(contact_inbox.pubsub_token)
    expect(subscription.send(:verify_toybaco_session)).to be(true)
  end
end
