# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::Oidc::SessionReader do
  let(:access_token) { 'browser-token' }
  let(:client) { 'browser-client' }
  let(:uid) { 'agent+alias@example.invalid' }
  let(:cookie) { { 'access-token' => access_token, 'client' => client, 'uid' => uid.tr('+', ' ') }.to_json }
  let(:relation) { instance_double(ActiveRecord::Relation) }

  before do
    allow(User).to receive(:where).with(uid: [uid.tr('+', ' '), uid]).and_return(relation)
  end

  it 'exactly one confirmed token matchだけを返す' do
    valid = instance_double(User, confirmed?: true)
    invalid = instance_double(User, confirmed?: true)
    allow(valid).to receive(:valid_token?).with(access_token, client).and_return(true)
    allow(invalid).to receive(:valid_token?).with(access_token, client).and_return(false)
    allow(relation).to receive(:to_a).and_return([valid, invalid])

    expect(described_class.new(cookie).user).to be(valid)
  end

  it '同じuidでtokenが複数利用者に一致したらfail closedにする' do
    candidates = Array.new(2) { instance_double(User, confirmed?: true) }
    candidates.each { |candidate| allow(candidate).to receive(:valid_token?).and_return(true) }
    allow(relation).to receive(:to_a).and_return(candidates)

    expect(described_class.new(cookie).user).to be_nil
  end

  it '候補が未確認またはtoken不一致だけなら返さない' do
    unconfirmed = instance_double(User, confirmed?: false)
    allow(relation).to receive(:to_a).and_return([unconfirmed])

    expect(described_class.new(cookie).user).to be_nil
  end

  it '壊れたcookieではUserを検索しない' do
    expect(User).not_to receive(:where)

    expect(described_class.new('{broken').user).to be_nil
  end
end
