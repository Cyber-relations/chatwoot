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

  before do
    skip '明示opt-inされた実Postiz test DBがありません' unless postiz_test_database?

    allow(Toybaco::PostizSync).to receive(:with_chatwoot_identity_locks).and_yield
    allow(Toybaco::PostizSync).to receive(:remember_organization)
    allow(Account).to receive(:find_by).with(id: account_id).and_return(account)
    allow(User).to receive(:find_by).with(id: user_id).and_return(user)
    allow(AccountUser).to receive(:find_by).with(user_id: user_id, account_id: account_id).and_return(account_user)
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

  private

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
        ["{#{organization_id},#{other_organization_id}}", "{#{postiz_user_id},#{poison_user_id}}"]
      )
      connection.exec_params(
        'DELETE FROM "Organization" WHERE id = ANY($1)', ["{#{organization_id},#{other_organization_id}}"]
      )
      connection.exec_params(
        'DELETE FROM "User" WHERE id = ANY($1)', ["{#{postiz_user_id},#{poison_user_id}}"]
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
