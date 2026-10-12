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
    let(:executed) { [] }
    # 無効への遷移(activated true→false)の UPDATE が返す、Postiz に保存されている解放前の email。Chatwoot 側の email
    # (user.email)とは別の値にして、解放にどちらが渡るかを見分ける。
    let(:deactivated_rows) { [{ 'email' => 'agent-stored@example.com' }] }

    before do
      allow(described_class).to receive(:with_transaction).and_yield
      allow(described_class).to receive(:lock_account!)
      allow(described_class).to receive(:exec) do |sql, params = []|
        executed_sql << sql.gsub(/\s+/, ' ').strip
        executed << [executed_sql.last, params]
        executed_sql.last.match?(/SET activated = false.*RETURNING (u\.)?email\z/) ? deactivated_rows : []
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

    it 'User削除で全所属を閉じ、無効へ遷移した本人行だけを、返った解放前のemailで「+released-<unix秒>-<user id>」付きへ解放する' do
      described_class.disable_user!(user_id: user.id)

      statements = executed.map(&:first)
      release = statements.index { |sql| sql.include?('SET email = CASE') }
      expect(release).to be > statements.index { |sql| sql.include?('SET activated = false') }
      sql, params = executed[release]
      expect(sql).to include([%{UPDATE "User" SET email = CASE WHEN strpos(email, '@') > 0 THEN regexp_replace(email, '@([^@]*)$',},
                              %{'+released-' || floor(extract(epoch FROM now()))::bigint || '-' || $3::bigint || '@\\1')},
                              %{ELSE email || '+released-' || floor(extract(epoch FROM now()))::bigint || '-' || $3::bigint END,}].join(' '))
      expect(sql).to include(%("providerName" = 'GENERIC'::"Provider" AND "providerId" = $1 AND id = $2 AND activated = false))
      expect(sql).to include(%{AND ($4::text IS NULL OR email = $4) AND NOT EXISTS ( SELECT 1 FROM "UserOrganization" uo})
      expect(sql).to include(%{WHERE uo."userId" = "User".id AND uo.disabled = false AND o."deletedAt" IS NULL ) RETURNING "providerId"})
      # 印は「+released-<unix 秒>-<user id>」(秒は SQL の now())。4 つ目の bind は遷移で返った解放前の email で、その
      # email の行だけを書き換える(解放済みの行は email が変わっているので書き換えない)。
      expect(params).to eq(["cw:#{user.id}", described_class.deterministic_user_id(user.id), user.id, 'agent-stored@example.com'])
      expect(statements.join('\n')).not_to include('DELETE')
    end

    it 'release_identity!をemailなしで呼ぶと4つ目のbindはnilで、SQLは$4がNULLならemailを見ない(運用のrakeの経路)' do
      described_class.release_identity!(user_id: user.id)

      sql, params = executed.last
      expect(sql).to include('AND ($4::text IS NULL OR email = $4)')
      expect(params).to eq(["cw:#{user.id}", described_class.deterministic_user_id(user.id), user.id, nil])
    end

    it '無効への遷移のUPDATEは、activated=trueの行だけを無効にして解放前のemailを返す' do
      described_class.disable_user!(user_id: user.id)
      described_class.revoke_membership!(user_id: user.id, account: account)

      deactivations = executed_sql.select { |sql| sql.include?('SET activated = false') }
      expect(deactivations.first).to end_with(%(AND "providerId" = $1 AND id = $2 AND activated = true RETURNING email))
      expect(deactivations.last).to include('AND u.activated = true AND NOT EXISTS (')
      expect(deactivations.last).to end_with('RETURNING u.email')
    end

    it '最後の所属を外す時の無効への遷移のUPDATEは、定数にした1文のままで、本人の行のproviderIdと決定的idだけをbindする' do
      described_class.revoke_membership!(user_id: user.id, account: account)

      sql, params = executed.find { |statement, _| statement.start_with?('UPDATE "User" u SET activated = false') }
      expect(sql).to eq(
        ['UPDATE "User" u SET activated = false, "updatedAt" = NOW()',
         %(WHERE u."providerName" = 'GENERIC'::"Provider" AND u."providerId" = $1 AND u.id = $2 AND u.activated = true),
         'AND NOT EXISTS ( SELECT 1 FROM "UserOrganization" uo JOIN "Organization" o ON o.id = uo."organizationId"',
         'WHERE uo."userId" = u.id AND uo.disabled = false AND o."deletedAt" IS NULL ) RETURNING u.email'].join(' ')
      )
      expect(params).to eq(["cw:#{user.id}", described_class.deterministic_user_id(user.id)])
    end

    it '無効への遷移が無ければ(既に無効の行)、User削除でも所属削除でも解放を呼ばない' do
      allow(described_class).to receive(:release_identity!)
      allow(described_class).to receive(:exec).and_return([])

      described_class.disable_user!(user_id: user.id)
      described_class.revoke_membership!(user_id: user.id, account: account)

      expect(described_class).not_to have_received(:release_identity!)
    end

    it '所属削除では所属を閉じたあとに本人の行の解放を試み、降格では解放しない' do
      described_class.demote_membership!(user_id: user.id, account: account)
      expect(executed_sql.join('\n')).not_to include('SET email')
      executed_sql.clear
      executed.clear

      described_class.revoke_membership!(user_id: user.id, account: account)

      releases = executed.select { |sql, _| sql.include?('SET email = CASE') }
      expect(releases.map(&:last)).to eq([["cw:#{user.id}", described_class.deterministic_user_id(user.id), user.id, 'agent-stored@example.com']])
      expect(executed_sql.index { |sql| sql.include?('SET email') }).to be > executed_sql.index { |sql| sql.include?('SET activated = false') }
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

  describe 'release_orphan!' do
    let(:orphan_id) { 2_901 }
    let(:row) { { 'id' => described_class.deterministic_user_id(orphan_id), 'providerId' => "cw:#{orphan_id}" } }
    let(:orphan_email) { 'orphan@example.com' }

    before do
      # 持ち主の Chatwoot user は居ない(孤児)。持ち主が居る場合は各 example で差し替える。
      allow(User).to receive(:find_by).with(id: orphan_id).and_return(nil)
      allow(described_class).to receive(:release_identity!).with(user_id: orphan_id.to_s, email: orphan_email).and_return("cw:#{orphan_id}")
    end

    it 'activatedが文字列のfの行を、同期中のemailを渡して孤児として解放する' do
      expect(described_class.send(:release_orphan!, row.merge('activated' => 'f'), email: orphan_email)).to be(true)
      expect(described_class).to have_received(:release_identity!).with(user_id: orphan_id.to_s, email: orphan_email)
    end

    it 'activatedがbooleanのfalseの行も孤児として解放し、t・true・nilは解放しない' do
      expect(described_class.send(:release_orphan!, row.merge('activated' => false), email: orphan_email)).to be(true)
      ['t', true, nil, 'false', 'true', 0, 1].each do |value|
        expect(described_class.send(:release_orphan!, row.merge('activated' => value), email: orphan_email)).to be(false), value.inspect
      end
      expect(described_class).to have_received(:release_identity!).once
    end

    it '孤児と判定したのに解放が0行ならwarnにproviderIdだけを残してfalseを返す' do
      allow(described_class).to receive(:release_identity!).with(user_id: orphan_id.to_s, email: orphan_email).and_return(nil)
      allow(Rails.logger).to receive(:warn)

      expect(described_class.send(:release_orphan!, row.merge('activated' => 'f'), email: orphan_email)).to be(false)
      expect(Rails.logger).to have_received(:warn).with("postiz identity orphan not released provider_id=cw:#{orphan_id}")
    end

    it '持ち主のChatwoot userが居ても現在のemailが行のemailと違えば(emailを変えた)、行のemailを渡して解放する' do
      allow(User).to receive(:find_by).with(id: orphan_id).and_return(instance_double(User, email: 'owner-changed@example.com'))

      expect(described_class.send(:release_orphan!, row.merge('activated' => 'f'), email: orphan_email)).to be(true)
      expect(described_class).to have_received(:release_identity!).with(user_id: orphan_id.to_s, email: orphan_email)
    end

    it '持ち主のChatwoot userが行と同じemailのままなら、解放を呼ばずfalseを返す' do
      allow(User).to receive(:find_by).with(id: orphan_id).and_return(instance_double(User, email: orphan_email))

      expect(described_class.send(:release_orphan!, row.merge('activated' => 'f'), email: orphan_email)).to be(false)
      expect(described_class).not_to have_received(:release_identity!)
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
