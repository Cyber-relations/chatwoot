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

  describe 'renewal session binding' do
    let(:now) { Time.utc(2026, 9, 17) }
    let(:record) { { 'token' => 'server-hashed-token', 'expiry' => now.to_i + 3600 } }
    let(:valid_user) { instance_double(User, confirmed?: true, tokens: { client => record }) }
    let(:reader) { described_class.new(cookie) }
    let(:binding) do
      reader.user
      reader.renewal_binding(valid_user)
    end

    before do
      allow(Time).to receive(:current).and_return(now)
      allow(valid_user).to receive(:valid_token?).with(access_token, client).and_return(true)
      allow(relation).to receive(:to_a).and_return([valid_user])
    end

    it '検証済みclientのrecord digestと認証時刻だけを保持する' do
      expect(binding.keys).to contain_exactly('client', 'record_digest', 'auth_time')
      expect(binding).to include('client' => client, 'auth_time' => now.to_i)
      expect(binding.fetch('record_digest')).to match(/\A[0-9a-f]{64}\z/)
      expect(binding.values).not_to include(access_token, record.fetch('token'))
      expect(described_class.renewal_current?(valid_user, binding)).to be(true)
    end

    it '再検証失敗後は以前のvalidated userを再利用しない' do
      expect(binding).to be_present
      allow(valid_user).to receive(:valid_token?).and_return(false)

      expect(reader.user).to be_nil
      expect(reader.renewal_binding(valid_user)).to be_nil
    end

    it 'logoutによるclient削除後は拒否する' do
      captured = binding
      valid_user.tokens.delete(client)

      expect(described_class.renewal_current?(valid_user, captured)).to be(false)
    end

    it 'current tokenまたはexpiryの変更を拒否する' do
      captured = binding
      record['token'] = 'rotated-server-hash'
      expect(described_class.renewal_current?(valid_user, captured)).to be(false)
      record['token'] = 'server-hashed-token'
      record['expiry'] += 1
      expect(described_class.renewal_current?(valid_user, captured)).to be(false)
    end

    it 'last_tokenとbatch時刻だけの更新は無効化理由にしない' do
      captured = binding
      record.merge!('last_token' => 'prior-hash', 'updated_at' => now.to_i + 1, 'last_token_updated_at' => now.to_i + 2)

      expect(described_class.renewal_current?(valid_user, captured)).to be(true)
    end

    it 'session期限と認証から600秒の境界を両方拒否する' do
      captured = binding
      allow(Time).to receive(:current).and_return(now + 600)
      expect(described_class.renewal_current?(valid_user, captured)).to be(false)
      allow(Time).to receive(:current).and_return(now)
      record['expiry'] = now.to_i
      expect(reader.renewal_binding(valid_user)).to be_nil
    end

    it '未確認利用者や壊れたbindingは拒否する' do
      captured = binding
      [nil, {}, captured.merge('auth_time' => now.to_i + 1), captured.merge('record_digest' => 'invalid')].each do |value|
        expect(described_class.renewal_current?(valid_user, value)).to be(false)
      end
      allow(valid_user).to receive(:confirmed?).and_return(false)
      expect(described_class.renewal_current?(valid_user, captured)).to be(false)
    end
  end
end
