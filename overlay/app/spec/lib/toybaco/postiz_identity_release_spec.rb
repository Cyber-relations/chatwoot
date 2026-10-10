# frozen_string_literal: true

require 'rails_helper'
require 'uri'

Rails.application.load_tasks unless Rake::Task.task_defined?('toybaco:postiz_identity_release')

# ops-rake toybaco:postiz_identity_release の解放・拒否・出力。新しい担当者は Chatwoot の実 record、削除済みの旧担当者の
# Postiz 行は admin 接続で作り、解放は同期 role の接続で行う。identity lock は stub しない。実 Postiz test DB は
# postiz_sync_database_spec と同じく、明示 opt-in で application / admin URL が同じ test 専用 DB を指す時だけ使う。
RSpec.describe 'toybaco:postiz_identity_release', type: :task do
  let(:release) { Toybaco::Ops::PostizIdentityRelease }
  let!(:account) { create(:account, internal_attributes: { 'postiz' => { 'enabled' => false } }) }
  let!(:user) { create(:user, name: '再追加の担当者') }
  # 削除済み(存在しない)Chatwoot user の id と、その user に同期が作った Postiz 行の決定的 id。
  let(:old_user_id) { User.maximum(:id).to_i + 1000 }
  let(:old_postiz_id) { Toybaco::PostizSync.deterministic_user_id(old_user_id) }
  let(:new_postiz_id) { Toybaco::PostizSync.deterministic_user_id(user.id) }
  let(:organization_id) { Toybaco::PostizSync.deterministic_organization_id(account.id) }
  let(:admin_connection) { PG.connect(ENV.fetch('TOYBACO_POSTIZ_TEST_ADMIN_DATABASE_URL')) }
  let(:prefix) { "TOYBACO_POSTIZ_IDENTITY_RELEASE user=#{user.id}" }
  let!(:baseline) { Toybaco::OperatorAction.maximum(:id).to_i }
  let(:seeded_user_ids) { [] }

  around { |example| with_modified_env(TOYBACO_OPS_ACTOR: nil, TOYBACO_OPS_SOURCE: nil) { example.run } }

  before do
    skip '明示opt-inされた実Postiz test DBがありません' unless postiz_test_database?

    # 店舗は担当者を加えた後で Postiz を有効にする(所属の作成時に同期を走らせない)。有効化の commit 後の一括同期は止める。
    create(:account_user, account: account, user: user, role: :agent)
    allow(Toybaco::PostizLifecycle).to receive(:reconcile_account)
    account.update!(internal_attributes: { 'postiz' => { 'enabled' => true } })
    clean_identity_rows
  end

  after do
    delete_committed_audit_rows(baseline)
    next unless postiz_test_database?

    clean_identity_rows
    Toybaco::PostizSync.send(:clear_connection!)
    admin_connection.close unless admin_connection.finished?
  end

  it '削除済みの旧担当者の行を tombstone にして解放し、新しい担当者の同期を積み、その同期が通る(2 回目は no-conflict)' do
    seed_postiz_user(old_postiz_id, "cw:#{old_user_id}", activated: true)
    seed_membership(old_postiz_id, disabled: true)
    expect { Toybaco::PostizSync.sync!(user: user, account: account) }
      .to raise_error(Toybaco::PostizSync::IdentityConflict, /同期前に作られた別の GENERIC 利用者/)

    expect(run_release).to eq(release_line('released', 'none', enqueued: true, postiz_id: old_postiz_id, chatwoot_id: old_user_id))
    expect(Toybaco::PostizMembershipJob).to have_been_enqueued.with(user.id, account.id).exactly(:once)
    expect(postiz_user(old_postiz_id)).to include('activated' => 'f')
    expect(postiz_user(old_postiz_id).fetch('email')).to match(tombstone_of(user.email, old_user_id))
    perform_enqueued_jobs(only: Toybaco::PostizMembershipJob)
    expect(postiz_user(new_postiz_id)).to include('email' => user.email, 'activated' => 't', 'providerId' => "cw:#{user.id}")
    expect(run_release).to eq(release_line('no-conflict', 'same-user'))
  end

  it '旧担当者の Chatwoot user が残っていれば書かずに refused(old-user-exists)と出し、同期を積まない' do
    other = create(:user)
    other_postiz_id = Toybaco::PostizSync.deterministic_user_id(other.id)
    seed_postiz_user(other_postiz_id, "cw:#{other.id}")

    expect(run_release).to eq(release_line('refused', 'old-user-exists', postiz_id: other_postiz_id, chatwoot_id: other.id))
    expect(postiz_user(other_postiz_id)).to include('email' => user.email, 'activated' => 'f')
    expect(Toybaco::PostizMembershipJob).not_to have_been_enqueued
  end

  it '旧行に有効な所属が残っていれば書かずに refused(old-user-has-memberships)と出し、同期を積まない' do
    seed_postiz_user(old_postiz_id, "cw:#{old_user_id}")
    seed_membership(old_postiz_id, disabled: false)

    expect(run_release).to eq(release_line('refused', 'old-user-has-memberships', postiz_id: old_postiz_id, chatwoot_id: old_user_id))
    expect(postiz_user(old_postiz_id)).to include('email' => user.email)
    expect(Toybaco::PostizMembershipJob).not_to have_been_enqueued
  end

  it '持ち主を確かめられない行(cw: の形でない providerId、決定的 id でない行)は書かずに refused(unknown-owner)と出す' do
    legacy_id = SecureRandom.uuid
    seed_postiz_user(legacy_id, 'legacy-signup')
    first = run_release
    clean_identity_rows
    stray_id = SecureRandom.uuid
    seed_postiz_user(stray_id, "cw:#{old_user_id}")

    expect(first).to eq(release_line('refused', 'unknown-owner', postiz_id: legacy_id))
    expect(run_release).to eq(release_line('refused', 'unknown-owner', postiz_id: stray_id))
    expect(postiz_user(stray_id)).to include('email' => user.email)
  end

  it '衝突の行が無ければ書かずに no-conflict と出して同期だけを積み直し、担当者が無ければ found=false と出して積まない' do
    missing = User.maximum(:id).to_i + 2000

    expect(run_release(missing.to_s)).to eq("TOYBACO_POSTIZ_IDENTITY_RELEASE user=#{missing} found=false")
    expect(Toybaco::PostizMembershipJob).not_to have_been_enqueued
    expect(run_release).to eq(release_line('no-conflict', 'none', enqueued: true))
    expect(Toybaco::PostizMembershipJob).to have_been_enqueued.with(user.id, account.id).exactly(:once)
    expect(postiz_user(new_postiz_id)).to be_nil
  end

  it 'どの結果の行にもメールアドレス・氏名を出さない(refused・released・no-conflict・found=false)' do
    other = create(:user)
    seed_postiz_user(Toybaco::PostizSync.deterministic_user_id(other.id), "cw:#{other.id}")
    outputs = [run_release]
    clean_identity_rows
    seed_postiz_user(old_postiz_id, "cw:#{old_user_id}")
    outputs.push(run_release, run_release, run_release((User.maximum(:id).to_i + 2000).to_s))

    expect(outputs.map { |line| line[/ state=\S+| found=false/] }).to eq([' state=refused', ' state=released', ' state=no-conflict', ' found=false'])
    expect(outputs.join("\n")).not_to include(user.email, user.email.split('@').first, user.name, other.email, other.name, '削除前の担当者', '@')
  end

  it 'release_identity! は本人の無効な行だけを書き換えて providerId を返し、有効な行と該当なしは nil で書かない' do
    seed_postiz_user(old_postiz_id, "cw:#{old_user_id}", activated: true)

    expect(Toybaco::PostizSync.release_identity!(user_id: old_user_id)).to be_nil
    expect(postiz_user(old_postiz_id)).to include('email' => user.email, 'activated' => 't')
    admin_connection.exec_params('UPDATE "User" SET activated = false WHERE id = $1', [old_postiz_id])
    expect(Toybaco::PostizSync.release_identity!(user_id: old_user_id)).to eq("cw:#{old_user_id}")
    expect(postiz_user(old_postiz_id).fetch('email')).to match(tombstone_of(user.email, old_user_id))
    expect(Toybaco::PostizSync.release_identity!(user_id: old_user_id + 1)).to be_nil
  end

  it 'release_identity! は有効な所属が付いた行を書き換えずに nil を返し、所属が disabled になれば解放する' do
    seed_postiz_user(old_postiz_id, "cw:#{old_user_id}")
    membership = seed_membership(old_postiz_id, disabled: false)

    expect(Toybaco::PostizSync.release_identity!(user_id: old_user_id)).to be_nil
    expect(postiz_user(old_postiz_id)).to include('email' => user.email)
    admin_connection.exec_params('UPDATE "UserOrganization" SET disabled = true WHERE id = $1', [membership])
    expect(Toybaco::PostizSync.release_identity!(user_id: old_user_id)).to eq("cw:#{old_user_id}")
  end

  it '判定の後に旧 user の同期が有効な所属を戻すと、解放は 0 行で IdentityConflict になり、書かずに戻して同期も積まない' do
    seed_postiz_user(old_postiz_id, "cw:#{old_user_id}")
    # 有効な所属の判定には「無い」と答えさせ、その後で所属が有効に戻った状態にする(判定と UPDATE の間の競合)。
    allow(Toybaco::PostizSync).to receive(:active_membership?).and_return(false)
    seed_membership(old_postiz_id, disabled: false)

    expect { run_release }.to raise_error(Toybaco::PostizSync::IdentityConflict, /解放が競合/)
    expect(postiz_user(old_postiz_id)).to include('email' => user.email, 'activated' => 'f')
    expect(Toybaco::PostizMembershipJob).not_to have_been_enqueued
  end

  it 'release_identity! は同じ秒に別の user が同じメールを解放しても、user id で区別して一意制約に当たらない' do
    second_user_id = old_user_id + 1
    second_postiz_id = Toybaco::PostizSync.deterministic_user_id(second_user_id)
    seed_postiz_user(old_postiz_id, "cw:#{old_user_id}")
    connection = Toybaco::PostizSync.send(:connection)

    # 1 つの transaction の中では now() が変わらないので、2 行の解放は同じ秒になる(製品コードは transaction を開かない)。
    # 2 行目は 1 行目が空けた email で、同じ transaction の中で作る(別の接続からだと、未確定の 1 行目と一意索引で待ち合う)。
    # user id の無い旧い形式(<local>+released-<秒>@<domain>)なら、2 行目の解放が 1 行目と同じ email になり一意制約違反になる。
    connection.transaction do
      expect(Toybaco::PostizSync.release_identity!(user_id: old_user_id)).to eq("cw:#{old_user_id}")
      seed_postiz_user(second_postiz_id, "cw:#{second_user_id}", via: connection)
      expect(Toybaco::PostizSync.release_identity!(user_id: second_user_id)).to eq("cw:#{second_user_id}")
    end
    first, second = [old_postiz_id, second_postiz_id].map { |id| postiz_user(id).fetch('email') }
    expect(first).to match(tombstone_of(user.email, old_user_id))
    expect(second).to match(tombstone_of(user.email, second_user_id))
    expect(first[/\+released-(\d+)-/, 1]).to eq(second[/\+released-(\d+)-/, 1])
  end

  it 'release_identity! は transaction を開かず、呼び出し側の transaction の一部として rollback で戻る' do
    seed_postiz_user(old_postiz_id, "cw:#{old_user_id}")
    rollback = Class.new(StandardError)

    expect do
      Toybaco::PostizSync.send(:connection).transaction do
        expect(Toybaco::PostizSync.release_identity!(user_id: old_user_id)).to eq("cw:#{old_user_id}")
        raise rollback
      end
    end.to raise_error(rollback)
    expect(postiz_user(old_postiz_id)).to include('email' => user.email)
  end

  # 試験の同期 role は 3 表への表単位の権限を持つ。本番の postiz_sync は列単位の権限だけなので
  # (infra/terraform/postiz-ecs.tf の GRANT)、同じ列権限の role に切り替えて解放が通ることを確かめる。
  it '本番の同期 role と同じ列権限(Post 表の権限なし)だけで、有効な旧行を無効にして解放できる' do
    seed_postiz_user(old_postiz_id, "cw:#{old_user_id}", activated: true)
    seed_membership(old_postiz_id, disabled: true)
    with_production_column_grants do
      expect(run_release).to eq(release_line('released', 'none', enqueued: true, postiz_id: old_postiz_id, chatwoot_id: old_user_id))
    end
    expect(postiz_user(old_postiz_id)).to include('activated' => 'f')
  end

  describe 'rake のタスク' do
    def run_task(*values)
      Rake::Task['toybaco:postiz_identity_release'].execute(Rake::TaskArguments.new([:chatwoot_user_id], values))
    end

    it 'run と同じ 1 行を出し、監査行に started と ok を残す' do
      expected = "#{release_line('no-conflict', 'none', enqueued: true)}\n"

      expect { run_task(user.id.to_s) }.to output(expected).to_stdout
      expect(Toybaco::OperatorAction.where('id > ?', baseline).order(:id).pluck(:action, :result)).to eq(
        [%w[rake.toybaco:postiz_identity_release started], %w[rake.toybaco:postiz_identity_release ok]]
      )
    end

    it 'chatwoot_user_id が 1 以上の整数の文字列でない時と、引数が 2 つ以上の時は書かずに abort する(入力の値は出さない)' do
      seed_postiz_user(old_postiz_id, "cw:#{old_user_id}")
      message = "TOYBACO_POSTIZ_IDENTITY_RELEASE_ABORT reason=user_id_invalid\n"

      ['0', '025', 'abc', '12345678901', nil].each do |value|
        expect { run_task(value) }.to raise_error(SystemExit).and output(message).to_stderr
      end
      expect { run_task(user.id) }.to raise_error(SystemExit).and output(message).to_stderr
      expect { run_task(user.id.to_s, '1') }.to raise_error(SystemExit).and output(message).to_stderr
      expect(postiz_user(old_postiz_id)).to include('email' => user.email)
    end
  end

  private

  def run_release(value = user.id.to_s)
    release.run(Rake::TaskArguments.new([:chatwoot_user_id], [value]))
  end

  # 期待する 1 行。旧行の Postiz id は先頭 8 字、旧 Chatwoot user id は逆算できた時だけ。
  def release_line(state, reason, enqueued: false, postiz_id: nil, chatwoot_id: nil)
    "#{prefix} old_postiz_user=#{postiz_id ? postiz_id[0, 8] : 'none'} old_chatwoot_user=#{chatwoot_id || 'none'} " \
      "state=#{state} reason=#{reason} enqueued=#{enqueued}"
  end

  # <local>+released-<unix 秒>-<chatwoot user id>@<domain>(メールの形を保ち、時刻と旧行の持ち主で一意)。
  def tombstone_of(email, user_id)
    local, _, domain = email.rpartition('@')
    /\A#{Regexp.escape(local)}\+released-\d{10,}-#{Integer(user_id)}@#{Regexp.escape(domain)}\z/
  end

  def postiz_test_database?
    return false unless ENV['TOYBACO_POSTIZ_DB_TEST_OPT_IN'] == '1'

    app_uri = URI.parse(ENV['TOYBACO_POSTIZ_DATABASE_URL'].to_s)
    admin_uri = URI.parse(ENV['TOYBACO_POSTIZ_TEST_ADMIN_DATABASE_URL'].to_s)
    [[app_uri, 'toybaco_sync_gate'], [admin_uri, 'postgres']].all? do |uri, role|
      [uri.scheme, uri.host, uri.user, uri.path] == ['postgresql', 'postgres', role, '/postiz_identity_test']
    end && app_uri.port == admin_uri.port
  rescue URI::InvalidURIError
    false
  end

  # 削除前の担当者の行(既定は削除で無効になった状態)。email は既定で新しい担当者と同じ。既定は admin 接続で作る。
  def seed_postiz_user(id, provider_id, email = user.email, activated: false, via: admin_connection)
    seeded_user_ids << id
    via.exec_params(
      <<~SQL.squish,
        INSERT INTO "User" (id, email, "providerName", "providerId", name, timezone, activated,
                            "createdAt", "updatedAt", "lastReadNotifications", "lastOnline")
        VALUES ($1, $2, 'GENERIC'::"Provider", $3, '削除前の担当者', 0, $4, NOW(), NOW(), NOW(), NOW())
      SQL
      [id, email, provider_id, activated]
    )
  end

  # 旧行の所属。作った所属の id を返す。
  def seed_membership(postiz_user_id, disabled:)
    id = SecureRandom.uuid
    admin_connection.exec_params(
      <<~SQL.squish,
        INSERT INTO "Organization" (id, name, "createdAt", "updatedAt") VALUES ($1, '解放テスト', NOW(), NOW())
        ON CONFLICT (id) DO NOTHING
      SQL
      [organization_id]
    )
    admin_connection.exec_params(
      <<~SQL.squish,
        INSERT INTO "UserOrganization" (id, "userId", "organizationId", role, disabled, "createdAt", "updatedAt")
        VALUES ($1, $2, $3, 'USER'::"Role", $4, NOW(), NOW())
      SQL
      [id, postiz_user_id, organization_id, disabled]
    )
    id
  end

  def probe_role
    'toybaco_release_probe'
  end

  # infra/terraform/postiz-ecs.tf の postiz_sync への GRANT と同じ列(Post など他の表には権限を与えない)。
  def production_column_grants
    <<~SQL.squish
      GRANT USAGE ON SCHEMA public TO #{probe_role};
      GRANT SELECT (id, name, "deletedAt") ON TABLE "Organization" TO #{probe_role};
      GRANT INSERT (id, name, "createdAt", "updatedAt", "allowTrial", "isTrailing") ON TABLE "Organization" TO #{probe_role};
      GRANT UPDATE (name, "updatedAt", "deletedAt", "apiKey") ON TABLE "Organization" TO #{probe_role};
      GRANT SELECT (id, email, "providerName", "providerId", activated, "deletedAt") ON TABLE "User" TO #{probe_role};
      GRANT INSERT (id, email, "providerName", "providerId", name, timezone, activated, "createdAt", "updatedAt",
                    "lastReadNotifications", "lastOnline") ON TABLE "User" TO #{probe_role};
      GRANT UPDATE (email, name, activated, "deletedAt", "updatedAt") ON TABLE "User" TO #{probe_role};
      GRANT SELECT ("userId", "organizationId", role, disabled) ON TABLE "UserOrganization" TO #{probe_role};
      GRANT INSERT (id, "userId", "organizationId", role, disabled, "createdAt", "updatedAt") ON TABLE "UserOrganization"
        TO #{probe_role};
      GRANT UPDATE (role, disabled, "updatedAt") ON TABLE "UserOrganization" TO #{probe_role};
    SQL
  end

  # 列権限だけの role を作って同期 role に付与し、PostizSync の接続をその role に切り替える。終わったら role を消す。
  def with_production_column_grants
    drop_probe_role
    admin_connection.exec("CREATE ROLE #{probe_role} NOLOGIN; #{production_column_grants} GRANT #{probe_role} TO toybaco_sync_gate")
    connection = Toybaco::PostizSync.send(:connection)
    connection.exec("SET ROLE #{probe_role}")
    expect(connection.exec('SELECT current_user').first.fetch('current_user')).to eq(probe_role)
    yield
  ensure
    Toybaco::PostizSync.send(:clear_connection!)
    drop_probe_role
  end

  def drop_probe_role
    exists = admin_connection.exec_params('SELECT 1 FROM pg_roles WHERE rolname = $1', [probe_role]).ntuples.positive?
    admin_connection.exec("DROP OWNED BY #{probe_role}; DROP ROLE #{probe_role}") if exists
  end

  def postiz_user(id)
    admin_connection.exec_params('SELECT email, activated, "providerId" FROM "User" WHERE id = $1', [id]).first
  end

  def clean_identity_rows
    ids = "{#{[old_postiz_id, new_postiz_id, *seeded_user_ids].uniq.join(',')}}"
    admin_connection.transaction do |connection|
      connection.exec_params('DELETE FROM "UserOrganization" WHERE "userId" = ANY($1) OR "organizationId" = $2', [ids, organization_id])
      connection.exec_params('DELETE FROM "User" WHERE id = ANY($1)', [ids])
      connection.exec_params('DELETE FROM "Organization" WHERE id = $1', [organization_id])
    end
  end

  # rake の監査行は別の DB セッションで確定させるため、transactional test のロールバックでは消えない(renewal_report_rake_spec と同じ)。
  def delete_committed_audit_rows(after_id)
    connection = ActiveRecord::Base.connection_db_config.new_connection
    connection.execute('SET session_replication_role = replica')
    connection.execute("DELETE FROM toybaco_operator_actions WHERE id > #{Integer(after_id)}")
  ensure
    connection&.disconnect!
  end
end
