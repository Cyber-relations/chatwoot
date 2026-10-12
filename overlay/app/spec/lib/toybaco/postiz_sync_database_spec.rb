# frozen_string_literal: true

require 'rails_helper'
require 'uri'

# 明示opt-inかつapplication/admin URLが同じtest専用DBを指すときだけ実行する。
# application側は固定Prisma 3表へのSELECT/INSERT/UPDATEだけを持つ同期roleで動かす。
RSpec.describe 'Toybaco PostizSync database contract', type: :model do
  let(:account_id) { 1_041 }
  let(:user_id) { 2_073 }
  let(:account) do
    instance_double(
      Account,
      id: account_id,
      name: 'DB契約テスト',
      active?: true,
      internal_attributes: { 'postiz' => { 'enabled' => true } }
    )
  end
  let(:user) { instance_double(User, id: user_id, email: 'identity-db-contract@example.invalid', name: 'DB契約') }
  let(:account_user) { instance_double(AccountUser, role: 'administrator') }
  let(:organization_id) { Toybaco::PostizSync.deterministic_organization_id(account_id) }
  let(:postiz_user_id) { Toybaco::PostizSync.deterministic_user_id(user_id) }
  let(:postiz_connection) { PG.connect(ENV.fetch('TOYBACO_POSTIZ_DATABASE_URL')) }
  let(:admin_connection) { PG.connect(ENV.fetch('TOYBACO_POSTIZ_TEST_ADMIN_DATABASE_URL')) }
  let(:other_account_id) { account_id + 1 }
  let(:other_organization_id) { Toybaco::PostizSync.deterministic_organization_id(other_account_id) }
  let(:poison_user_id) { '00000000-0000-5000-8000-000000000073' }
  # 削除した利用者と同じメールで作り直した、別の Chatwoot 利用者。
  let(:new_user_id) { user_id + 1 }
  let(:new_user) { instance_double(User, id: new_user_id, email: user.email, name: 'DB契約 再追加') }

  before do
    skip '明示opt-inされた実Postiz test DBがありません' unless postiz_test_database?

    allow(Toybaco::PostizSync).to receive(:with_chatwoot_identity_locks).and_yield
    allow(Toybaco::PostizSync).to receive(:remember_organization)
    allow(Account).to receive(:find_by).with(id: account_id).and_return(account)
    allow(User).to receive(:find_by).with(id: user_id).and_return(user)
    allow(AccountUser).to receive(:find_by).with(user_id: user_id, account_id: account_id).and_return(account_user)
    allow(User).to receive(:find_by).with(id: new_user_id).and_return(new_user)
    allow(AccountUser).to receive(:find_by).with(user_id: new_user_id, account_id: account_id).and_return(account_user)
    clean_identity_rows
  end

  after do
    clean_identity_rows if postiz_test_database?
    Toybaco::PostizSync.send(:clear_connection!)
    postiz_connection.close if postiz_test_database? && !postiz_connection.finished?
    admin_connection.close if postiz_test_database? && !admin_connection.finished?
  end

  it '同時初回loginが同じOrganization/User/UserOrganization各1行へ収束する' do
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    errors = Queue.new
    workers = Array.new(2) do
      Thread.new do
        ready << true
        start.pop
        results << Toybaco::PostizSync.sync!(user: user, account: account)
      rescue StandardError => e
        errors << e
      ensure
        Toybaco::PostizSync.send(:clear_connection!)
      end
    end
    workers.length.times { ready.pop }
    workers.length.times { start << true }
    workers.each(&:join)

    raise errors.pop unless errors.empty?

    contexts = Array.new(workers.length) { results.pop }
    expect(contexts.pluck(:organization_id).uniq).to eq([organization_id])
    expect(row_count('Organization', 'id', organization_id)).to eq(1)
    expect(row_count('User', 'id', postiz_user_id)).to eq(1)
    expect(row_count('UserOrganization', 'organizationId', organization_id)).to eq(1)
  end

  it '外部commit後のChatwoot mapping保存失敗から次回同一UUIDを回収する' do
    calls = 0
    allow(Toybaco::PostizSync).to receive(:remember_organization) do
      calls += 1
      raise Toybaco::PostizSync::MappingConflict if calls == 1
    end

    expect { Toybaco::PostizSync.sync!(user: user, account: account) }
      .to raise_error(Toybaco::PostizSync::MappingConflict)
    recovered = Toybaco::PostizSync.sync!(user: user, account: account)

    expect(recovered.fetch(:organization_id)).to eq(organization_id)
    expect(row_count('Organization', 'id', organization_id)).to eq(1)
    expect(row_count('UserOrganization', 'organizationId', organization_id)).to eq(1)
  end

  it '降格・所属削除で本人のrole/sessionだけを失効し組織共有API keyを維持する' do
    Toybaco::PostizSync.sync!(user: user, account: account)
    admin_connection.exec_params(
      'UPDATE "Organization" SET "apiKey" = $2 WHERE id = $1',
      [organization_id, 'stale-contract-key']
    )

    Toybaco::PostizSync.demote_membership!(user_id: user_id, account: account)
    demoted = identity_row
    expect(demoted).to include('role' => 'USER', 'disabled' => 'false', 'apiKey' => 'stale-contract-key')

    Toybaco::PostizSync.revoke_membership!(user_id: user_id, account: account)

    revoked = identity_row
    expect(revoked).to include(
      'activated' => 'false', 'disabled' => 'true', 'apiKey' => 'stale-contract-key'
    )
    expect do
      Toybaco::PostizSync.access_context(user: user, account: account, organization_id: organization_id)
    end.to raise_error(Toybaco::PostizSync::AccessRevoked)
  end

  it '同期roleは固定3表の必要操作だけを持ちDDL/DELETEを持たない' do
    expect(postiz_connection.exec('SELECT current_user').first.fetch('current_user')).to eq('toybaco_sync_gate')
    grants = admin_connection.exec(<<~SQL.squish).map { |row| row.values_at('table_name', 'privilege_type') }
      SELECT table_name, privilege_type
        FROM information_schema.role_table_grants
       WHERE grantee = 'toybaco_sync_gate'
       ORDER BY table_name, privilege_type
    SQL
    expect(grants).to eq(
      [
        %w[Organization INSERT], %w[Organization SELECT], %w[Organization UPDATE],
        %w[User INSERT], %w[User SELECT], %w[User UPDATE],
        %w[UserOrganization INSERT], %w[UserOrganization SELECT], %w[UserOrganization UPDATE]
      ]
    )
    expect_forbidden_database_mutations(
      postiz_connection
    )
  end

  it '別tenantを指す保存organization mappingをrename/undelete/membership追加せず拒否する' do
    seed_other_tenant
    poisoned_account = instance_double(
      Account,
      id: account_id,
      name: '攻撃側名称',
      active?: true,
      internal_attributes: { 'postiz' => { 'enabled' => true, 'organization_id' => other_organization_id } }
    )
    allow(Account).to receive(:find_by).with(id: account_id).and_return(poisoned_account)

    expect { Toybaco::PostizSync.sync!(user: user, account: poisoned_account) }
      .to raise_error(Toybaco::PostizSync::MappingConflict)

    row = admin_connection.exec_params(
      'SELECT name, "deletedAt" FROM "Organization" WHERE id = $1', [other_organization_id]
    ).first
    expect(row).to include('name' => 'B社', 'deletedAt' => nil)
    expect(row_count('UserOrganization', 'organizationId', other_organization_id)).to eq(1)
  end

  it 'cw providerIdを持つ別ID userと他tenant所属を引き継がず拒否する' do
    seed_other_tenant(provider_id: "cw:#{user_id}")

    expect { Toybaco::PostizSync.sync!(user: user, account: account) }
      .to raise_error(Toybaco::PostizSync::IdentityConflict, /別の user id/)

    row = admin_connection.exec_params(
      'SELECT "userId", "organizationId", disabled::text FROM "UserOrganization" WHERE "userId" = $1',
      [poison_user_id]
    ).first
    expect(row).to include('userId' => poison_user_id, 'organizationId' => other_organization_id, 'disabled' => 'false')
    expect(row_count('Organization', 'id', organization_id)).to eq(0)
  end

  it '利用者を削除したあと、同じメールで作り直した利用者を同期できる(旧行のemailを解放する)' do
    Toybaco::PostizSync.sync!(user: user, account: account)
    allow(Rails.logger).to receive(:info).and_call_original

    Toybaco::PostizSync.disable_user!(user_id: user_id)

    expect(user_row(postiz_user_id)).to include('email' => released_email, 'activated' => 'false', 'providerId' => "cw:#{user_id}")
    released = user_row(postiz_user_id).slice('email', 'activated', 'providerId')
    expect(Rails.logger).to have_received(:info).with("postiz identity released provider_id=cw:#{user_id}")
    # 2 回目の削除は無効への遷移が無いので解放しない。同じ email を渡した単独の解放も 0 行(解放済みの行は email が
    # 変わっている)で nil、email は変わらない(冪等)。
    Toybaco::PostizSync.disable_user!(user_id: user_id)
    expect(Toybaco::PostizSync.release_identity!(user_id: user_id, email: user.email)).to be_nil
    expect(user_row(postiz_user_id)).to include(released)

    result = Toybaco::PostizSync.sync!(user: new_user, account: account)

    expect(result).to include(organization_id: organization_id, user_id: new_postiz_user_id)
    expect(user_row(new_postiz_user_id)).to include('email' => user.email, 'activated' => 'true', 'providerId' => "cw:#{new_user_id}")
    expect(user_row(postiz_user_id)).to include(released)
  end

  it '所属削除では、最後の所属を閉じたときだけemailを解放し、所属へ戻すと元のemailへ戻す' do
    other_account = instance_double(Account, id: other_account_id, name: 'B社', active?: true,
                                             internal_attributes: { 'postiz' => { 'enabled' => true } })
    allow(Account).to receive(:find_by).with(id: other_account_id).and_return(other_account)
    allow(AccountUser).to receive(:find_by).with(user_id: user_id, account_id: other_account_id).and_return(account_user)
    Toybaco::PostizSync.sync!(user: user, account: account)
    Toybaco::PostizSync.sync!(user: user, account: other_account)

    Toybaco::PostizSync.revoke_membership!(user_id: user_id, account: account)
    expect(user_row(postiz_user_id)).to include('email' => user.email, 'activated' => 'true')

    Toybaco::PostizSync.revoke_membership!(user_id: user_id, account: other_account)
    expect(user_row(postiz_user_id)).to include('email' => released_email, 'activated' => 'false')

    Toybaco::PostizSync.sync!(user: user, account: account)
    expect(user_row(postiz_user_id)).to include('email' => user.email, 'activated' => 'true')
  end

  it '削除前から残る孤児行(cw:のproviderId・Chatwoot userなし・activated=false)は同期のときに解放してから作る' do
    seed_identity_user(postiz_user_id, "cw:#{user_id}", activated: false)
    allow(User).to receive(:find_by).with(id: user_id).and_return(nil)
    allow(Toybaco::PostizSync).to receive(:release_orphan!).and_call_original

    Toybaco::PostizSync.sync!(user: new_user, account: account)

    expect(Toybaco::PostizSync).to have_received(:release_orphan!).with(hash_including('providerId' => "cw:#{user_id}"), email: new_user.email)
    expect(user_row(postiz_user_id)).to include('email' => released_email, 'activated' => 'false')
    expect(user_row(new_postiz_user_id)).to include('email' => user.email, 'activated' => 'true', 'providerId' => "cw:#{new_user_id}")
  end

  it '運用のrakeと同じく単独で呼ぶと、activated=falseの本人行だけを解放してproviderIdを返す' do
    seed_identity_user(postiz_user_id, "cw:#{user_id}", activated: true)
    expect(Toybaco::PostizSync.release_identity!(user_id: user_id)).to be_nil
    expect(user_row(postiz_user_id)).to include('email' => user.email)

    admin_connection.exec_params('UPDATE "User" SET activated = false WHERE id = $1', [postiz_user_id])
    released = Toybaco::PostizSync.release_identity!(user_id: user_id)

    expect(released).to eq("cw:#{user_id}")
    expect(user_row(postiz_user_id)).to include('email' => released_email, 'activated' => 'false')
    Toybaco::PostizSync.sync!(user: new_user, account: account)
    expect(user_row(new_postiz_user_id)).to include('email' => user.email, 'activated' => 'true')
  end

  it 'activated=falseでも有効な所属が残る行は解放せずnilを返し、孤児としても扱わない' do
    Toybaco::PostizSync.sync!(user: user, account: account)
    # 所属の判定の後に旧 user の同期が所属を戻した状態(activated=false のまま有効な所属がある)。
    admin_connection.exec_params('UPDATE "User" SET activated = false WHERE id = $1', [postiz_user_id])
    allow(User).to receive(:find_by).with(id: user_id).and_return(nil)

    expect(Toybaco::PostizSync.release_identity!(user_id: user_id)).to be_nil
    expect(user_row(postiz_user_id)).to include('email' => user.email, 'activated' => 'false')
    expect_identity_kept(postiz_user_id)
  end

  it 'メールを削除済み利用者の旧アドレスへ変えた利用者は、旧行が孤児なら解放して同期し、旧利用者がいれば拒否する' do
    seed_identity_user(orphan_postiz_user_id, "cw:#{orphan_user_id}", activated: false)
    before_change = instance_double(User, id: user_id, email: 'identity-db-contract-before@example.invalid', name: 'DB契約')
    allow(User).to receive(:find_by).with(id: user_id).and_return(before_change)
    Toybaco::PostizSync.sync!(user: before_change, account: account)
    allow(User).to receive(:find_by).with(id: user_id).and_return(user)

    # 旧利用者が居て、旧行と同じ email のまま。
    allow(User).to receive(:find_by).with(id: orphan_user_id).and_return(instance_double(User, id: orphan_user_id, email: user.email))
    expect { Toybaco::PostizSync.sync!(user: user, account: account) }
      .to raise_error(Toybaco::PostizSync::IdentityConflict, /別利用者を指しています/)
    expect(user_row(orphan_postiz_user_id)).to include('email' => user.email)

    allow(User).to receive(:find_by).with(id: orphan_user_id).and_return(nil)
    Toybaco::PostizSync.sync!(user: user, account: account)

    expect(user_row(orphan_postiz_user_id)).to include('email' => released_email(orphan_user_id), 'activated' => 'false')
    expect(user_row(postiz_user_id)).to include('email' => user.email, 'activated' => 'true', 'providerId' => "cw:#{user_id}")
  end

  # 秒は SQL の now()。1 つの transaction の中では now() が変わらないので、2 行の解放は同じ秒になる(製品コードは
  # release_identity! では transaction を開かない)。2 行目は 1 行目が空けた email で、同じ transaction の中で作る(別の
  # 接続からだと、未確定の 1 行目と一意索引で待ち合う)。
  it '同じ秒に同じメールを別の利用者が解放しても、印のuser idで衝突せずrollbackしない' do
    seed_identity_user(postiz_user_id, "cw:#{user_id}", activated: false)
    connection = Toybaco::PostizSync.send(:connection)

    connection.transaction do
      expect(Toybaco::PostizSync.release_identity!(user_id: user_id, email: user.email)).to eq("cw:#{user_id}")
      seed_identity_user(new_postiz_user_id, "cw:#{new_user_id}", activated: false, via: connection)
      expect(Toybaco::PostizSync.release_identity!(user_id: new_user_id, email: user.email)).to eq("cw:#{new_user_id}")
    end

    first, second = [postiz_user_id, new_postiz_user_id].map { |id| user_row(id).fetch('email') }
    expect([first, second]).to match([released_email, released_email(new_user_id)])
    expect(first[/\+released-(\d+)-/, 1]).to eq(second[/\+released-(\d+)-/, 1])
  end

  # 解放の鍵は無効への遷移。解放済みの行に、削除・最後の所属の削除が来ても遷移が無いので解放を呼ばない(User の削除の後の
  # AccountUser の削除や 2 回目の削除に当たる)。同期の孤児・email 付きの単独の呼び出しは、guard(email = 解放前の email)で
  # 0 行になる。どの経路でも印を重ねない。
  it '解放済みの行は、削除・最後の所属の削除では解放を呼ばず、同期の孤児・email付きの単独では0行で、印を重ねない' do
    Toybaco::PostizSync.sync!(user: user, account: account)
    Toybaco::PostizSync.disable_user!(user_id: user_id)
    released = user_row(postiz_user_id).fetch('email')
    expect(released).to released_email
    allow(User).to receive(:find_by).with(id: user_id).and_return(nil)
    allow(Toybaco::PostizSync).to receive(:release_identity!).and_call_original
    allow(Rails.logger).to receive(:warn)
    orphan = { 'id' => postiz_user_id, 'providerId' => "cw:#{user_id}", 'activated' => 'f' }

    Toybaco::PostizSync.disable_user!(user_id: user_id)
    2.times { Toybaco::PostizSync.revoke_membership!(user_id: user_id, account: account) }
    expect(Toybaco::PostizSync).not_to have_received(:release_identity!)
    expect(Toybaco::PostizSync.send(:release_orphan!, orphan, email: user.email)).to be(false)
    expect(Toybaco::PostizSync.release_identity!(user_id: user_id, email: user.email)).to be_nil

    expect(Toybaco::PostizSync).to have_received(:release_identity!).with(user_id: anything, email: user.email).twice
    expect(user_row(postiz_user_id)).to include('email' => released, 'activated' => 'false')
  end

  # Chatwoot で email を変えた直後の同期が失敗して、Postiz の行が旧い email のまま最後の所属を外す。解放は Postiz に
  # 保存されている旧い email で行うので(Chatwoot の現在の email ではない)、別の利用者が旧い email で同期できる。
  it 'Chatwootのemailを変えた後の同期が失敗してPostizの行が旧いemailのままでも、最後の所属を外すと旧いemailで解放する' do
    Toybaco::PostizSync.sync!(user: user, account: account)
    changed = instance_double(User, id: user_id, email: 'identity-db-contract-changed@example.invalid', name: 'DB契約')
    allow(User).to receive(:find_by).with(id: user_id).and_return(changed)
    expect(user_row(postiz_user_id)).to include('email' => user.email, 'activated' => 'true')

    Toybaco::PostizSync.revoke_membership!(user_id: user_id, account: account)

    expect(user_row(postiz_user_id)).to include('email' => released_email, 'activated' => 'false')
    expect { Toybaco::PostizSync.sync!(user: new_user, account: account) }.not_to raise_error
    expect(user_row(new_postiz_user_id)).to include('email' => user.email, 'activated' => 'true', 'providerId' => "cw:#{new_user_id}")
  end

  it '元のメールが+released-<数字>@を含む利用者も、削除で解放して同じメールで作り直せる' do
    email = 'identity-db-contract+released-123@example.invalid'
    allow(User).to receive(:find_by).with(id: user_id).and_return(instance_double(User, id: user_id, email: email, name: 'DB契約'))
    again = instance_double(User, id: new_user_id, email: email, name: 'DB契約 再追加')
    allow(User).to receive(:find_by).with(id: new_user_id).and_return(again)
    Toybaco::PostizSync.sync!(user: User.find_by(id: user_id), account: account)

    Toybaco::PostizSync.disable_user!(user_id: user_id)

    expect(user_row(postiz_user_id)).to include(
      'email' => released_email(user_id, local: 'identity-db-contract+released-123'), 'activated' => 'false'
    )
    expect { Toybaco::PostizSync.sync!(user: again, account: account) }.not_to raise_error
    expect(user_row(new_postiz_user_id)).to include('email' => email, 'activated' => 'true')
  end

  # 解放済みかどうかを印の形で見ると、本人の正規メールが偶然 <local>+released-<数字>-<自分の uid>@<domain> の形のとき
  # 永久に解放できない。解放前の email との完全一致で見るので、この形のメールも解放できる。
  it '本人の正規メールが+released-<秒>-<自分のuid>@の形でも、削除で解放して同じメールで作り直せる' do
    email = "agent+released-1720000000-#{user_id}@example.invalid"
    allow(User).to receive(:find_by).with(id: user_id).and_return(instance_double(User, id: user_id, email: email, name: 'DB契約'))
    again = instance_double(User, id: new_user_id, email: email, name: 'DB契約 再追加')
    allow(User).to receive(:find_by).with(id: new_user_id).and_return(again)
    Toybaco::PostizSync.sync!(user: User.find_by(id: user_id), account: account)

    expect(Toybaco::PostizSync.disable_user!(user_id: user_id)).to eq(:disabled)

    expect(user_row(postiz_user_id)).to include(
      'email' => released_email(user_id, local: "agent+released-1720000000-#{user_id}"), 'activated' => 'false'
    )
    expect { Toybaco::PostizSync.sync!(user: again, account: account) }.not_to raise_error
    expect(user_row(new_postiz_user_id)).to include('email' => email, 'activated' => 'true')
  end

  it '同じメールの行が存在するChatwoot利用者のもの・activatedのまま・決定的idでないなら解放せず拒否する' do
    allow(User).to receive(:find_by).with(id: user_id).and_return(user)
    seed_identity_user(postiz_user_id, "cw:#{user_id}", activated: false)
    expect_identity_kept(postiz_user_id)

    allow(User).to receive(:find_by).with(id: user_id).and_return(nil)
    admin_connection.exec_params('UPDATE "User" SET activated = true WHERE id = $1', [postiz_user_id])
    expect_identity_kept(postiz_user_id)

    clean_identity_rows
    seed_identity_user(poison_user_id, "cw:#{user_id}", activated: false)
    expect_identity_kept(poison_user_id)
  end

  # 店舗停止(disable_account!)で先に無効になった本人の行は、その後に最後の所属を外しても無効への遷移が無いので解放されない。
  # 持ち主が Chatwoot の email を変えた後に、別の利用者が旧い email で管理店舗に入ると、同期がその行を解放してから作る。
  it '店舗停止で先に無効になった行は所属削除では解放されず、持ち主がemailを変えた後の別利用者の同期で解放する' do
    allow(Rails.logger).to receive(:warn)
    suspend_store_and_remove_member
    stub_existing_owner(email: 'identity-db-contract-changed@example.invalid')

    result = Toybaco::PostizSync.sync!(user: new_user, account: account)

    expect(result).to include(organization_id: organization_id, user_id: new_postiz_user_id)
    expect(user_row(postiz_user_id)).to include('email' => released_email, 'activated' => 'false', 'providerId' => "cw:#{user_id}")
    expect(user_row(new_postiz_user_id)).to include('email' => user.email, 'activated' => 'true', 'providerId' => "cw:#{new_user_id}")
    expect(Rails.logger).not_to have_received(:warn)
  end

  it '店舗停止で先に無効になった行でも、持ち主が同じemailのままなら別利用者の同期で解放せず拒否する' do
    suspend_store_and_remove_member
    stub_existing_owner(email: user.email)

    expect_identity_kept(postiz_user_id)
    expect(user_row(postiz_user_id)).to include('activated' => 'false', 'providerId' => "cw:#{user_id}")
  end

  # 無効への遷移の後に解放が 0 行(遷移と解放の間に有効な所属が戻った等)。戻り値は変えず、providerId だけを warn に残す。
  it '無効へ遷移したのに解放が0行なら、User削除でも最後の所属の削除でもwarnにproviderIdだけを残し、戻り値は変えない' do
    Toybaco::PostizSync.sync!(user: user, account: account)
    allow(Toybaco::PostizSync).to receive(:release_identity!).and_return(nil)
    allow(Rails.logger).to receive(:warn)
    warning = "postiz identity not released after deactivation provider_id=cw:#{user_id}"

    expect(Toybaco::PostizSync.disable_user!(user_id: user_id)).to eq(:disabled)
    expect(Rails.logger).to have_received(:warn).with(warning).once
    Toybaco::PostizSync.sync!(user: user, account: account)
    expect(Toybaco::PostizSync.revoke_membership!(user_id: user_id, account: account)).to eq(:revoked)

    expect(Rails.logger).to have_received(:warn).with(warning).twice
    expect(Toybaco::PostizSync).to have_received(:release_identity!).with(user_id: user_id, email: user.email).twice
    expect(user_row(postiz_user_id)).to include('email' => user.email, 'activated' => 'false')
  end

  private

  # 店舗停止(disable_account!)で本人の行が先に無効(email はそのまま)になり、その後に最後の所属を外しても
  # (revoke_membership!)無効への遷移が無いので解放されない状態を作る。
  def suspend_store_and_remove_member
    Toybaco::PostizSync.sync!(user: user, account: account)
    Toybaco::PostizSync.disable_account!(account: account)
    expect(user_row(postiz_user_id)).to include('email' => user.email, 'activated' => 'false')
    Toybaco::PostizSync.revoke_membership!(user_id: user_id, account: account)
    expect(user_row(postiz_user_id)).to include('email' => user.email, 'activated' => 'false')
  end

  # 持ち主(user_id)の Chatwoot user は存在し(exists? も find_by も居ると答える)、現在の email は email。
  def stub_existing_owner(email:)
    allow(User).to receive(:exists?).and_call_original
    allow(User).to receive(:exists?).with(id: user_id).and_return(true)
    allow(User).to receive(:find_by).with(id: user_id).and_return(instance_double(User, id: user_id, email: email, name: 'DB契約'))
  end

  def new_postiz_user_id
    Toybaco::PostizSync.deterministic_user_id(new_user_id)
  end

  # 削除済み(Chatwoot に居ない)利用者の旧行。
  def orphan_user_id
    2_901
  end

  def orphan_postiz_user_id
    Toybaco::PostizSync.deterministic_user_id(orphan_user_id)
  end

  # <local>+released-<unix 秒>-<chatwoot user id>@<domain>。秒は SQL の now() なので形だけを見る。
  def released_email(id = user_id, local: 'identity-db-contract')
    a_string_matching(/\A#{Regexp.escape(local)}\+released-\d{10,}-#{Integer(id)}@example\.invalid\z/)
  end

  def expect_identity_kept(row_id)
    expect { Toybaco::PostizSync.sync!(user: new_user, account: account) }
      .to raise_error(Toybaco::PostizSync::IdentityConflict, /同期前に作られた別の GENERIC/)
    expect(user_row(row_id)).to include('email' => user.email)
    expect(row_count('User', 'id', new_postiz_user_id)).to eq(0)
  end

  def user_row(row_id)
    admin_connection.exec_params(
      'SELECT email, activated::text, "providerId" FROM "User" WHERE id = $1', [row_id]
    ).first
  end

  def seed_identity_user(row_id, provider_id, activated:, via: admin_connection)
    via.exec_params(
      <<~SQL.squish,
        INSERT INTO "User" (id, email, "providerName", "providerId", name, timezone, activated,
                            "createdAt", "updatedAt", "lastReadNotifications", "lastOnline")
        VALUES ($1, $2, 'GENERIC'::"Provider", $3, '削除済み利用者', 0, $4, NOW(), NOW(), NOW(), NOW())
      SQL
      [row_id, user.email, provider_id, activated]
    )
  end

  def expect_forbidden_database_mutations(connection)
    expect do
      connection.exec_params('DELETE FROM "Organization" WHERE id = $1', [organization_id])
    end.to raise_error(PG::InsufficientPrivilege)
    expect do
      connection.exec('CREATE TABLE public.toybaco_forbidden_ddl (id integer)')
    end.to raise_error(PG::InsufficientPrivilege)
  end

  def postiz_test_database?
    return false unless ENV['TOYBACO_POSTIZ_DB_TEST_OPT_IN'] == '1'

    app_uri = URI.parse(ENV['TOYBACO_POSTIZ_DATABASE_URL'].to_s)
    admin_uri = URI.parse(ENV['TOYBACO_POSTIZ_TEST_ADMIN_DATABASE_URL'].to_s)
    exact_postiz_test_uri?(app_uri, user: 'toybaco_sync_gate') &&
      exact_postiz_test_uri?(admin_uri, user: 'postgres') &&
      app_uri.port == admin_uri.port
  rescue URI::InvalidURIError
    false
  end

  def exact_postiz_test_uri?(uri, user:)
    [uri.scheme, uri.host, uri.user, uri.path] ==
      ['postgresql', 'postgres', user, '/postiz_identity_test']
  end

  def clean_identity_rows
    admin_connection.transaction do |connection|
      connection.exec_params(
        'DELETE FROM "UserOrganization" WHERE "organizationId" = ANY($1) OR "userId" = ANY($2)',
        ["{#{organization_id},#{other_organization_id}}",
         "{#{postiz_user_id},#{poison_user_id},#{new_postiz_user_id},#{orphan_postiz_user_id}}"]
      )
      connection.exec_params(
        'DELETE FROM "Organization" WHERE id = ANY($1)', ["{#{organization_id},#{other_organization_id}}"]
      )
      connection.exec_params(
        'DELETE FROM "User" WHERE id = ANY($1)',
        ["{#{postiz_user_id},#{poison_user_id},#{new_postiz_user_id},#{orphan_postiz_user_id}}"]
      )
    end
  end

  def row_count(table, column, value)
    allowed = {
      'Organization' => ['id'],
      'User' => ['id'],
      'UserOrganization' => ['organizationId']
    }
    raise ArgumentError, '許可されていないtest用SQLです' unless allowed.fetch(table, []).include?(column)

    admin_connection.exec_params(
      %(SELECT COUNT(*) FROM "#{table}" WHERE "#{column}" = $1),
      [value]
    ).first.fetch('count').to_i
  end

  def identity_row
    admin_connection.exec_params(
      <<~SQL.squish,
        SELECT u.activated::text, uo.disabled::text, uo.role::text, o."apiKey"
          FROM "User" u
          JOIN "UserOrganization" uo ON uo."userId" = u.id
          JOIN "Organization" o ON o.id = uo."organizationId"
         WHERE u.id = $1 AND o.id = $2
      SQL
      [postiz_user_id, organization_id]
    ).first
  end

  def seed_other_tenant(provider_id: 'cw:other')
    admin_connection.transaction do |connection|
      seed_other_organization(connection)
      seed_other_user(connection, provider_id)
      seed_other_membership(connection)
    end
  end

  def seed_other_organization(connection)
    connection.exec_params(
      'INSERT INTO "Organization" (id, name, "createdAt", "updatedAt") VALUES ($1, \'B社\', NOW(), NOW())',
      [other_organization_id]
    )
  end

  def seed_other_user(connection, provider_id)
    connection.exec_params(
      <<~SQL.squish,
        INSERT INTO "User" (id, email, "providerName", "providerId", name, timezone,
                            "createdAt", "updatedAt", "lastReadNotifications", "lastOnline")
        VALUES ($1, 'poison@example.invalid', 'GENERIC'::"Provider", $2, '別利用者', 0,
                NOW(), NOW(), NOW(), NOW())
      SQL
      [poison_user_id, provider_id]
    )
  end

  def seed_other_membership(connection)
    connection.exec_params(
      <<~SQL.squish,
        INSERT INTO "UserOrganization" (id, "userId", "organizationId", role, "createdAt", "updatedAt")
        VALUES ('00000000-0000-5000-8000-000000000099', $1, $2, 'ADMIN'::"Role", NOW(), NOW())
      SQL
      [poison_user_id, other_organization_id]
    )
  end
end
