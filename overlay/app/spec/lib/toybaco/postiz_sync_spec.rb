# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::PostizSync do
  let(:organization_id) { described_class.deterministic_organization_id(41) }
  let(:account) do
    instance_double(
      Account,
      id: 41,
      name: 'A社',
      active?: true,
      internal_attributes: { 'postiz' => { 'enabled' => true, 'organization_id' => organization_id } }
    )
  end
  let(:user) { instance_double(User, id: 73, email: 'agent@example.com', name: '担当者') }
  let(:account_user) { instance_double(AccountUser, role: 'administrator') }

  before do
    allow(described_class).to receive(:configured?).and_return(true)
    allow(AccountUser).to receive(:find_by).with(user_id: user.id, account_id: account.id).and_return(account_user)
    allow(described_class).to receive(:with_chatwoot_identity_locks).and_yield
    allow(User).to receive(:find_by).with(id: user.id).and_return(user)
    allow(Account).to receive(:find_by).with(id: account.id).and_return(account)
  end

  describe '.sync!' do
    before do
      allow(described_class).to receive(:with_transaction).and_yield
      allow(described_class).to receive(:lock_account!)
      allow(described_class).to receive(:ensure_organization)
      allow(described_class).to receive(:ensure_user).and_return('postiz-user')
      allow(described_class).to receive(:ensure_membership)
      allow(described_class).to receive(:verify_access!).and_return('user_id' => 'postiz-user', 'role' => 'ADMIN')
    end

    it '同期行を検証した後だけtrusted organizationを返す' do
      result = described_class.sync!(user: user, account: account)

      expect(described_class).to have_received(:verify_access!).with(user.id, organization_id, 'ADMIN')
      expect(result).to eq(organization_id: organization_id, user_id: 'postiz-user', role: 'ADMIN')
    end

    it 'membership検証に失敗したら成功扱いにしない' do
      allow(described_class).to receive(:verify_access!).and_raise(described_class::AccessRevoked)

      expect { described_class.sync!(user: user, account: account) }.to raise_error(described_class::AccessRevoked)
    end

    it '未知のChatwoot roleを一般利用者へ丸めず拒否する' do
      allow(account_user).to receive(:role).and_return('custom-role')
      expect(described_class).not_to receive(:ensure_membership)

      expect { described_class.sync!(user: user, account: account) }
        .to raise_error(described_class::Ineligible, /role/)
    end

    it 'account mapping保存の前後で同じ決定的UUIDへ収束する' do
      unmapped = instance_double(
        Account,
        id: 41,
        name: 'A社',
        active?: true,
        internal_attributes: { 'postiz' => { 'enabled' => true } }
      )
      allow(AccountUser).to receive(:find_by).with(user_id: user.id, account_id: unmapped.id).and_return(account_user)
      allow(Account).to receive(:find_by).with(id: unmapped.id).and_return(unmapped)
      remember_calls = 0
      allow(described_class).to receive(:remember_organization) do
        remember_calls += 1
        raise described_class::MappingConflict if remember_calls == 1
      end

      expect { described_class.sync!(user: user, account: unmapped) }.to raise_error(described_class::MappingConflict)
      expect { described_class.sync!(user: user, account: unmapped) }.not_to raise_error

      expected = described_class.deterministic_organization_id(unmapped.id)
      expect(described_class).to have_received(:ensure_organization).with(unmapped, expected).twice
    end

    it '保存mappingが別tenant UUIDを指す場合はPostiz transaction前に拒否する' do
      poisoned = instance_double(
        Account,
        id: 41,
        name: 'A社',
        active?: true,
        internal_attributes: {
          'postiz' => { 'enabled' => true, 'organization_id' => described_class.deterministic_organization_id(42) }
        }
      )
      allow(Account).to receive(:find_by).with(id: poisoned.id).and_return(poisoned)
      allow(AccountUser).to receive(:find_by).with(user_id: user.id, account_id: poisoned.id).and_return(account_user)
      expect(described_class).not_to receive(:with_transaction)

      expect { described_class.sync!(user: user, account: poisoned) }
        .to raise_error(described_class::MappingConflict, /決定的ID/)
    end
  end

  describe 'revocation contract' do
    let(:executed_sql) { [] }

    before do
      allow(described_class).to receive(:with_transaction).and_yield
      allow(described_class).to receive(:lock_account!)
      allow(described_class).to receive(:exec) do |sql, _params = []|
        executed_sql << sql.gsub(/\s+/, ' ').strip
        []
      end
    end

    it '所属削除で本人のmembershipと最後のsession userだけを即時失効する' do
      described_class.revoke_membership!(user_id: user.id, account: account)

      joined = executed_sql.join('\n')
      expect(joined).to include('UPDATE "UserOrganization" uo')
      expect(joined).to include('SET disabled = true')
      expect(joined).not_to include('UPDATE "Organization" SET "apiKey" = NULL')
      expect(joined).to include('u."providerName" = \'GENERIC\'::"Provider"')
      expect(joined).to include('SET activated = false')
    end

    it '管理者から一般利用者への変更では本人のroleだけを落とす' do
      described_class.demote_membership!(user_id: user.id, account: account)

      joined = executed_sql.join('\n')
      expect(joined).to include("SET role = 'USER'::\"Role\"")
      expect(joined).not_to include('UPDATE "Organization" SET "apiKey" = NULL')
      expect(joined).not_to include('SET disabled = true')
    end

    it 'account停止で全membershipと旧API keyを失効する' do
      described_class.disable_account!(account: account)

      joined = executed_sql.join('\n')
      expect(joined).to include('UPDATE "UserOrganization"')
      expect(joined).to include('SET disabled = true')
      expect(joined).to include('UPDATE "Organization" SET "apiKey" = NULL')
    end

    it 'User削除で本人の全membershipとsession userだけを失効する' do
      described_class.disable_user!(user_id: user.id)

      joined = executed_sql.join('\n')
      expect(joined).to include('UPDATE "UserOrganization" uo')
      expect(joined).to include('SET disabled = true')
      expect(joined).not_to include('UPDATE "Organization" SET "apiKey" = NULL')
      expect(joined).to include('UPDATE "User"')
      expect(joined).to include('SET activated = false')
    end

    it 'least-privilege同期ロールの対象を3表だけに保つ' do
      described_class.revoke_membership!(user_id: user.id, account: account)
      described_class.demote_membership!(user_id: user.id, account: account)
      described_class.disable_account!(account: account)
      described_class.disable_user!(user_id: user.id)

      table_names = executed_sql.join('\n').scan(/"(Organization|UserOrganization|User|OAuthAuthorization)"/).flatten.uniq
      expect(table_names).to contain_exactly('Organization', 'UserOrganization', 'User')
      expect(executed_sql.join('\n')).not_to include('OAuthAuthorization')
    end
  end

  describe '.access_context' do
    it '選択accountに束縛されたactive membershipとroleを毎回再検証する' do
      allow(described_class).to receive(:verify_access!).and_return('user_id' => 'postiz-user', 'role' => 'ADMIN')

      result = described_class.access_context(user: user, account: account, organization_id: organization_id)

      expect(result).to eq(organization_id: organization_id, user_id: 'postiz-user', role: 'ADMIN')
    end

    it '別accountのorganization UUIDならDBを読む前に拒否する' do
      expect(described_class).not_to receive(:verify_access!)

      expect do
        described_class.access_context(user: user, account: account, organization_id: SecureRandom.uuid)
      end.to raise_error(described_class::AccessRevoked)
    end

    it '保存mapping自体がpoisonされていれば一致するclaimでも拒否する' do
      poisoned_id = described_class.deterministic_organization_id(42)
      allow(account).to receive(:internal_attributes).and_return(
        'postiz' => { 'enabled' => true, 'organization_id' => poisoned_id }
      )
      expect(described_class).not_to receive(:verify_access!)

      expect do
        described_class.access_context(user: user, account: account, organization_id: poisoned_id)
      end.to raise_error(described_class::AccessRevoked)
    end

    it '未知のChatwoot roleは発行済みtokenでも拒否する' do
      allow(account_user).to receive(:role).and_return('custom-role')
      expect(described_class).not_to receive(:verify_access!)

      expect do
        described_class.access_context(user: user, account: account, organization_id: organization_id)
      end.to raise_error(described_class::AccessRevoked, /role/)
    end
  end

  describe 'deterministic ids' do
    it '同じChatwoot IDの同時実行が同一UUIDへ収束する' do
      results = Queue.new
      workers = Array.new(20) do
        Thread.new { results << described_class.deterministic_organization_id(account.id) }
      end
      workers.each(&:join)
      ids = Array.new(workers.length) { results.pop }

      expect(ids.uniq.one?).to be(true)
      expect(ids.first).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
      expect(described_class.deterministic_user_id(user.id)).not_to eq(ids.first)
    end
  end
end
