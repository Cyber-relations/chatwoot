# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::Security::CableSession do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:credentials) { user.create_new_auth_token }
  let(:request) do
    instance_double(ActionDispatch::Request, cookies: { 'cw_d_session_info' => credentials.to_json },
                                             headers: { 'Origin' => 'https://app.example.test' }, base_url: 'https://app.example.test')
  end

  def bound_session
    described_class.new(request, user.id, account.id)
  end

  it 'requires the actual current DTA token in addition to a stream identifier' do
    session = bound_session
    expect(session.authenticate).to eq(user)
    expect(session.current?).to be(true)
  end

  it 'rejects a pubsub identifier without a login credential' do
    allow(request).to receive(:cookies).and_return({})
    expect(bound_session.authenticate).to be_nil
  end

  it 'rejects cross-origin cookie subscriptions' do
    allow(request).to receive(:headers).and_return({ 'Origin' => 'https://evil.example.test' })
    expect(bound_session.authenticate).to be_nil
  end

  it 'rejects cookie subscriptions without an Origin' do
    allow(request).to receive(:headers).and_return({})
    expect(bound_session.authenticate).to be_nil
  end

  it 'accepts explicit native WebSocket token headers' do
    allow(request).to receive(:cookies).and_return({})
    allow(request).to receive(:headers).and_return(credentials)
    expect(bound_session.authenticate).to eq(user)
  end

  it 'rejects user substitution and access to another tenant' do
    other = create(:user, account: create(:account))
    expect(described_class.new(request, other.id, account.id).authenticate).to be_nil
    expect(described_class.new(request, user.id, other.accounts.first.id).authenticate).to be_nil
  end

  it 'revokes an established binding immediately when the server token is removed' do
    session = bound_session
    expect(session.authenticate).to eq(user)
    user.update!(tokens: {})
    expect(session.current?).to be(false)
  end

  it 'revokes an established binding when the account membership is removed' do
    session = bound_session
    expect(session.authenticate).to eq(user)
    user.account_users.find_by!(account_id: account.id).destroy!
    expect(session.current?).to be(false)
  end

  it 'revokes an established binding when the password changes' do
    session = bound_session
    expect(session.authenticate).to eq(user)
    user.update!(password: 'ChangedPassword1!')
    expect(session.current?).to be(false)
  end

  it 'revokes an established binding at token expiry' do
    session = bound_session
    expect(session.authenticate).to eq(user)
    travel_to Time.at(credentials['expiry'].to_i + 1).utc do
      expect(session.current?).to be(false)
    end
  end
end
