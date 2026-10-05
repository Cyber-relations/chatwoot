# frozen_string_literal: true

require 'rails_helper'
require 'active_support/testing/stream'

Rails.application.load_tasks unless Rake::Task.task_defined?('toybaco:legal_consents_by_name')

# staging の E2E(規約同意の記録の経路の確認)用の運営 rake(toybaco:legal_consents_by_name / e2e_confirm_user / e2e_purge_accounts)。
# 読み取りの行の形とメールアドレス・氏名を出さないこと、書き込みの 2 本が staging 以外で引数を読む前に abort すること、e2e-consent- の形と
# 書き込みの 2 本が扱う店舗名の厳格な形(e2e-consent-r<run>-<attempt>)の検査、確認と選んだ店舗だけの有効化(1 transaction)、削除の範囲
# (対象の店舗と、その店舗にだけ所属する E2E 用の利用者。契約者が外れれば削除しない)と上限、commit 後の job、削除の取り消しを確かめる。
# Postiz の DB は外部の境界として PostizSync をスタブし(postiz_lifecycle_spec と同じ)、削除で無効化が呼ばれることを確かめる。
# 置き場所は他の overlay spec(spec/lib/toybaco/*_spec.rb)と揃え、rspec manifest の名簿で固定している。
RSpec.describe Toybaco::Ops::E2eConsent do # rubocop:disable RSpec/SpecFilePathFormat
  include ActiveSupport::Testing::Stream
  include ActiveJob::TestHelper

  let!(:baseline) { Toybaco::OperatorAction.maximum(:id).to_i }
  let(:staging_only) { 'は staging 専用です。production と環境が不明なときは実行しません。' }
  let(:prefix_error) { 'prefix は e2e-consent- に続けて英小文字・数字・- を 1〜40 字で指定してください。' }
  # 形に合わない prefix(空・e2e-consent- だけ・大文字・_ や % を含む・41 字・前後の空白や改行・別の名前・Symbol・nil)。
  let(:invalid_prefixes) do
    [nil, '', 'e2e-consent-', 'e2e-consent', 'E2E-consent-a', 'e2e-consent-A', 'e2e-consent-a_b', 'e2e-consent-a%', 'e2e-consent-%',
     "e2e-consent-#{'a' * 41}", ' e2e-consent-a', "e2e-consent-a\n", 'x-e2e-consent-a', 'shop', :'e2e-consent-a']
  end

  around do |example|
    with_modified_env(TOYBACO_DEPLOYMENT_ENVIRONMENT: 'staging', TOYBACO_OPS_ACTOR: nil, TOYBACO_OPS_SOURCE: nil) { example.run }
  end

  before do
    allow(Toybaco::PostizSync).to receive(:sync!).and_return(organization_id: 'postiz-org', user_id: 'postiz-user', role: 'ADMIN')
    allow(Toybaco::PostizSync).to receive(:revoke_membership!).and_return(:revoked)
    allow(Toybaco::PostizSync).to receive(:disable_account!).and_return(:disabled)
    allow(Toybaco::PostizSync).to receive(:disable_user!).and_return(:disabled)
  end

  # rake の監査行は別の DB セッションで確定させるため、transactional test のロールバックでは消えない(ops_rake_audit_spec と同じ後片付け)。
  after { delete_committed_rows(baseline) }

  def delete_committed_rows(after_id)
    connection = ActiveRecord::Base.connection_db_config.new_connection
    connection.execute('SET session_replication_role = replica')
    connection.execute("DELETE FROM toybaco_operator_actions WHERE id > #{Integer(after_id)}")
  ensure
    connection&.disconnect!
  end

  def new_rows
    Toybaco::OperatorAction.where('id > ?', baseline).order(:id)
  end

  def run_task(name, *values)
    task = Rake::Task["toybaco:#{name}"]
    task.execute(Rake::TaskArguments.new(task.arg_names, values))
  end

  # 成功するはずの呼び出し。想定外の abort(SystemExit)は RSpec の実行全体を止めるため、この例の失敗に置き換える。
  def run!(name, *values)
    capture(:stdout) { run_task(name, *values) }.lines(chomp: true)
  rescue SystemExit
    raise RSpec::Expectations::ExpectationNotMetError, "toybaco:#{name}[#{values.join(',')}] が abort しました"
  end

  # abort することを確かめ、abort の文(標準エラー)を返す。標準出力には何も出さない。
  def refusal(name, *values)
    message = nil
    printed = capture(:stdout) { message = capture(:stderr) { expect { run_task(name, *values) }.to raise_error(SystemExit) } }
    expect(printed).to eq('')
    message.chomp
  end

  # 無料登録の正本(FreeRegistration#register!)で、E2E の店舗(停止中)と未確認の利用者を作る。氏名は出力に出ないことを確かめるため店舗名と変える。
  def register(run, email: "qa+e2e-consent-#{run}@example.com")
    Toybaco::Growth::FreeRegistration.new.register!(account_name: "e2e-consent-#{run}", user_full_name: "規約 確認 #{run}",
                                                    email: email, password: 'Passw0rd!x2Y')
  end

  # メール確認待ちの無料登録の記録(FreeRegistration#register! と同じ鍵)。契約者を差し替えた店舗を作るときに使う。
  def registration_state(owner_id)
    { 'toybaco_growth_registration' => { 'phase' => 'email_pending', 'owner_id' => owner_id } }
  end

  def phase(account)
    account.reload.internal_attributes.dig('toybaco_growth_registration', 'phase')
  end

  describe 'toybaco:legal_consents_by_name' do
    it '名前が prefix で始まる店舗だけを id の順に legal_consents と同じ行で出し、最後に店舗数を出す(production でも動き、記録を書き換えない)' do
      user = create(:user, name: '規約 確認子', email: 'consent-owner@example.com')
      first = create(:account, name: 'e2e-consent-run1')
      second = create(:account, name: 'e2e-consent-run1-b')
      ['e2e-consent-run2', 'shop e2e-consent-run1', 'E2E-consent-run1', 'e2e-consentrun1'].each { |name| create(:account, name: name) }
      # 記録の順は無料登録・体験開始・自動応答の開始。出力の経路は _ を - にした表記。
      records = [%w[free_registration 2026-10-05T01:00:00Z], %w[trial 2026-10-05T02:00:00Z], %w[managed_auto 2026-10-05T03:00:00Z]]
      records.each { |route, at| Toybaco::LegalTerms.record!(first, route: route, accepted_at: at, user_id: user.id) }
      saved = [first, second].map { |account| account.reload.attributes.slice('internal_attributes', 'updated_at') }
      lines = with_modified_env(TOYBACO_DEPLOYMENT_ENVIRONMENT: 'production') { run!('legal_consents_by_name', 'e2e-consent-run1') }
      expect(lines).to eq(
        records.map do |route, at|
          "TOYBACO_LEGAL_CONSENT account=#{first.id} route=#{route.tr('_', '-')} terms_version=#{Toybaco::LegalTerms::VERSION} " \
            "accepted_at=#{at} user_id=#{user.id} session=- stripe_consent=-"
        end + ["TOYBACO_LEGAL_CONSENTS account=#{first.id} count=3 routes=free-registration:1,managed-auto:1,trial:1",
               "TOYBACO_LEGAL_CONSENTS account=#{second.id} count=0 routes=-",
               'TOYBACO_LEGAL_CONSENTS_BY_NAME prefix=e2e-consent-run1 accounts=2']
      )
      expect(lines.join("\n")).not_to include(user.email, user.name, '@')
      expect([first, second].map { |account| account.reload.attributes.slice('internal_attributes', 'updated_at') }).to eq(saved)
      digest = Toybaco::Ops::Audit.params_digest({ 'prefix' => 'e2e-consent-run1' })
      expect(new_rows.pluck(:action, :result, :params_digest)).to eq(
        [['rake.toybaco:legal_consents_by_name', 'started', digest], ['rake.toybaco:legal_consents_by_name', 'ok', digest]]
      )
    end

    it '一致する店舗が無くても店舗数 0 の 1 行だけを出して正常に終わる' do
      create(:account, name: 'e2e-consent-other')
      expect(run!('legal_consents_by_name', 'e2e-consent-none')).to eq(['TOYBACO_LEGAL_CONSENTS_BY_NAME prefix=e2e-consent-none accounts=0'])
      expect(new_rows.pluck(:result)).to eq(%w[started ok])
    end

    it 'prefix が e2e-consent- の形でないか余分な引数があれば、入力を出さずに abort し、failed を残す' do
      invalid_prefixes.each { |value| expect(refusal('legal_consents_by_name', value)).to eq(prefix_error) }
      expect(refusal('legal_consents_by_name', 'e2e-consent-a', 'x')).to eq('引数は prefix の 1 つだけを指定してください。')
      expect(new_rows.pluck(:result)).to eq(%w[started failed] * (invalid_prefixes.size + 1))
    end
  end

  describe 'toybaco:e2e_confirm_user' do
    it 'staging で、名前が prefix で始まるメール確認待ちの店舗の契約者を確認メールのリンクと同じ確認で確かめ、無料登録を有効にし、id と段階だけを出す' do
      user, account = register('r101-1')
      other_user, other = register('r101-2')
      _, outside = register('r102-1')
      create(:account, name: 'e2e-consent-r101-3')
      expect([user.confirmed?, account.status, phase(account)]).to eq([false, 'suspended', 'email_pending'])
      lines = run!('e2e_confirm_user', 'e2e-consent-r101-')
      expect(lines).to eq(["TOYBACO_E2E_CONFIRM user=#{user.id} account=#{account.id} phase=active",
                           "TOYBACO_E2E_CONFIRM user=#{other_user.id} account=#{other.id} phase=active",
                           'TOYBACO_E2E_CONFIRM prefix=e2e-consent-r101- accounts=2'])
      expect([user.reload.confirmed?, other_user.reload.confirmed?, account.reload.status, other.reload.status])
        .to eq([true, true, 'active', 'active'])
      expect([phase(outside), Toybaco::LegalTerms.records(account).pluck('route')]).to eq(['email_pending', ['free_registration']])
      expect(run!('e2e_confirm_user', 'e2e-consent-r101-')).to eq(['TOYBACO_E2E_CONFIRM prefix=e2e-consent-r101- accounts=0'])
      expect(lines.join("\n")).not_to include('@', 'qa+', user.name, other_user.name)
    end

    it '有効化は選んだ店舗ごとの FreeRegistration#activate! だけで行い、確認の commit 後の処理(FreeConfirmation・FreeActivationJob)には残さない' do
      user, account = register('r111-1')
      allow(Toybaco::Growth::FreeRegistration).to receive(:new).and_call_original
      expect(run!('e2e_confirm_user', 'e2e-consent-r111-1'))
        .to eq(["TOYBACO_E2E_CONFIRM user=#{user.id} account=#{account.id} phase=active", 'TOYBACO_E2E_CONFIRM prefix=e2e-consent-r111-1 accounts=1'])
      expect(Toybaco::Growth::FreeRegistration).to have_received(:new).once
      expect(Toybaco::FreeActivationJob).not_to have_been_enqueued
      expect(account.reload.status).to eq('active')
    end

    it 'local 部が e2e-consent-<tag> そのもののメールアドレスの契約者も確認できる' do
      user, account = register('r110-1', email: 'e2e-consent-r110-1@example.com')
      expect(run!('e2e_confirm_user', 'e2e-consent-r110-1').first).to eq("TOYBACO_E2E_CONFIRM user=#{user.id} account=#{account.id} phase=active")
      expect(user.reload.confirmed?).to be(true)
    end

    it '監査行に started と ok が残り、params_digest は prefix の digest' do
      register('r112-1')
      run!('e2e_confirm_user', 'e2e-consent-r112-1')
      digest = Toybaco::Ops::Audit.params_digest({ 'prefix' => 'e2e-consent-r112-1' })
      expect(new_rows.pluck(:action, :result, :params_digest)).to eq(
        [['rake.toybaco:e2e_confirm_user', 'started', digest], ['rake.toybaco:e2e_confirm_user', 'ok', digest]]
      )
    end

    it 'production と環境が不明なときは、引数を読む前に abort して確認しない' do
      user, account = register('r103-1')
      [{ TOYBACO_DEPLOYMENT_ENVIRONMENT: 'production' }, { TOYBACO_DEPLOYMENT_ENVIRONMENT: nil },
       { TOYBACO_DEPLOYMENT_ENVIRONMENT: 'Staging' }].each do |env|
        with_modified_env(env) do
          expect(refusal('e2e_confirm_user', 'e2e-consent-r103-1')).to eq("e2e_confirm_user #{staging_only}")
          expect(refusal('e2e_confirm_user', '%')).to eq("e2e_confirm_user #{staging_only}")
        end
      end
      expect([user.reload.confirmed?, phase(account)]).to eq([false, 'email_pending'])
      expect(new_rows.pluck(:result)).to eq(%w[started failed] * 6)
    end

    it 'prefix が e2e-consent- の形でないか余分な引数があれば、入力を出さずに abort して確認しない' do
      user, = register('r199-1')
      invalid_prefixes.each { |value| expect(refusal('e2e_confirm_user', value)).to eq(prefix_error) }
      expect(refusal('e2e_confirm_user', 'e2e-consent-r199-1', 'x')).to eq('引数は prefix の 1 つだけを指定してください。')
      expect(user.reload.confirmed?).to be(false)
      expect(new_rows.pluck(:result)).to eq(%w[started failed] * (invalid_prefixes.size + 1))
    end

    it 'prefix に一致した店舗に E2E の店舗名の形(e2e-consent-r<run>-<attempt>)でないもの(別の名前・後ろに続きがある名前)があれば、1 件も確認せずに abort する' do
      user, account = register('r117-1')
      create(:account, name: 'e2e-consent-registration')
      create(:account, name: 'e2e-consent-r117-2-old')
      expect(refusal('e2e_confirm_user', 'e2e-consent-r'))
        .to eq('prefix=e2e-consent-r に一致する店舗に、E2E の店舗名の形(e2e-consent-r<run>-<attempt>)でない店舗が 2 件あるため確認しません。')
      expect([user.reload.confirmed?, phase(account)]).to eq([false, 'email_pending'])
    end

    it 'メール確認待ちの店舗が上限の 5 件を超えれば 1 件も確認せずに abort し、5 件ちょうどなら確認する' do
      registrations = (1..6).map { |index| register("r141-#{index}") }
      expect(refusal('e2e_confirm_user', 'e2e-consent-r141-'))
        .to eq('prefix=e2e-consent-r141- に一致するメール確認待ちの店舗が 6 件あり、1 回の上限 5 件を超えるため確認しません。prefix を絞ってください。')
      expect(registrations.map { |user, _| user.reload.confirmed? }.uniq).to eq([false])
      registrations.last.last.update!(name: 'e2e-consent-r142-6')
      expect(run!('e2e_confirm_user', 'e2e-consent-r141-').last).to eq('TOYBACO_E2E_CONFIRM prefix=e2e-consent-r141- accounts=5')
      expect(registrations.map { |user, _| user.reload.confirmed? }).to eq(([true] * 5) + [false])
    end

    it '契約者が見つからないか E2E の利用者でない店舗があれば、どの店舗の契約者も確認せずに abort する' do
      user, account = register('r105-1')
      broken = create(:account, name: 'e2e-consent-r105-2', internal_attributes: registration_state(0))
      expect(refusal('e2e_confirm_user', 'e2e-consent-r105-')).to eq("account=#{broken.id} の無料登録の契約者が見つかりません。")
      shared, shared_store = register('r106-1')
      create(:account_user, account: create(:account, name: '本番の店舗'), user: shared, role: :agent)
      outsider, outsider_store = register('r107-1', email: 'owner-r107@example.com')
      admin = create(:super_admin, email: 'qa+e2e-consent-r108-1@example.com', confirmed_at: nil)
      admin_store = create(:account, name: 'e2e-consent-r108-1', internal_attributes: registration_state(admin.id))
      create(:account_user, account: admin_store, user: admin, role: :administrator)
      [[shared_store, shared], [outsider_store, outsider], [admin_store, admin]].each do |store, owner|
        expect(refusal('e2e_confirm_user', store.name))
          .to eq("account=#{store.id} の契約者 user=#{owner.id} は E2E の利用者ではないため確認しません。")
      end
      expect([user, shared, outsider, admin].map { |owner| owner.reload.confirmed? } + [phase(account)]).to eq(([false] * 4) + ['email_pending'])
    end

    it '無料登録が有効にならなければ(段階が active でなければ)段階を出して abort し、確認も取り消す(1 つの transaction)' do
      user, account = register('r109-1')
      allow(Toybaco::Growth::FreeRegistration).to receive(:new).and_return(instance_double(Toybaco::Growth::FreeRegistration, activate!: nil))
      expect(refusal('e2e_confirm_user', 'e2e-consent-r109-1'))
        .to eq("無料登録が有効になっていない店舗があります(TOYBACO_E2E_CONFIRM user=#{user.id} account=#{account.id} phase=email_pending)。")
      expect([user.reload.confirmed?, account.reload.status, phase(account)]).to eq([false, 'suspended', 'email_pending'])
    end

    it 'User#confirm が確認を記録できなければ、理由の種類(属性と error のキー)だけを出して abort する' do
      user, account = register('r113-1')
      allow(User).to receive(:find_by).and_call_original
      allow(User).to receive(:find_by).with(id: user.id).and_return(user)
      allow(user).to receive(:confirm) do
        user.errors.add(:email, :confirmation_period_expired, period: '3 days')
        false
      end
      expect(refusal('e2e_confirm_user', 'e2e-consent-r113-1')).to eq("user=#{user.id} のメール確認を記録できません(email.confirmation_period_expired)。")
      expect([user.reload.confirmed?, phase(account)]).to eq([false, 'email_pending'])
    end

    it '契約者が選んだ店舗の外にもメール確認待ちの店舗を持てば(確認するとその店舗も有効になる)、確認せずに abort する' do
      user, account = register('r114-1')
      other = create(:account, name: 'e2e-consent-r914-1', internal_attributes: registration_state(user.id))
      create(:account_user, account: other, user: user, role: :administrator)
      expect(refusal('e2e_confirm_user', 'e2e-consent-r114-1'))
        .to eq("account=#{account.id} の契約者 user=#{user.id} は選んだ店舗の外にもメール確認待ちの店舗を持つため確認しません。")
      expect([user.reload.confirmed?, phase(account), phase(other)]).to eq([false, 'email_pending', 'email_pending'])
    end

    it '2 件目の確認が記録できなければ、1 件目の確認と有効化も取り消す(1 つの transaction)' do
      first_user, first = register('r115-1')
      second_user, second = register('r115-2')
      allow(User).to receive(:find_by).and_call_original
      allow(User).to receive(:find_by).with(id: second_user.id).and_return(second_user)
      allow(second_user).to receive(:confirm) do
        second_user.errors.add(:email, :confirmation_period_expired, period: '3 days')
        false
      end
      expect(refusal('e2e_confirm_user', 'e2e-consent-r115-'))
        .to eq("user=#{second_user.id} のメール確認を記録できません(email.confirmation_period_expired)。")
      expect([first_user.reload.confirmed?, first.reload.status, phase(first), phase(second)])
        .to eq([false, 'suspended', 'email_pending', 'email_pending'])
    end

    it '2 件目の有効化が例外になれば、1 件目の確認と有効化も取り消す(1 つの transaction)' do
      first_user, first = register('r116-1')
      second_user, second = register('r116-2')
      calls = 0
      allow(Toybaco::Growth::FreeRegistration).to receive(:new).and_wrap_original do |original, *arguments|
        registration = original.call(*arguments)
        calls += 1
        allow(registration).to receive(:activate!).and_raise(ActiveRecord::ActiveRecordError, 'activation failed') if calls == 2
        registration
      end
      expect { capture(:stdout) { run_task('e2e_confirm_user', 'e2e-consent-r116-') } }
        .to raise_error(ActiveRecord::ActiveRecordError, 'activation failed')
      expect([first_user.reload.confirmed?, second_user.reload.confirmed?]).to eq([false, false])
      expect([first.reload.status, phase(first), phase(second)]).to eq(%w[suspended email_pending email_pending])
      expect(new_rows.pluck(:result)).to eq(%w[started failed])
    end
  end

  describe 'toybaco:e2e_purge_accounts' do
    it 'staging で、名前が prefix で始まる店舗と、その店舗にだけ所属する E2E 用の利用者を削除し、ほかは残す' do
      owner, store = register('r201-1')
      other_owner, other_store = register('r201-2')
      kept_account = create(:account, name: '残す店舗')
      staff = create(:user, email: 'staff@example.com', account: store, role: :agent)
      create(:account_user, account: kept_account, user: staff, role: :agent)
      admin = create(:super_admin, email: 'qa+e2e-consent-r201-admin@example.com')
      create(:account_user, account: store, user: admin, role: :administrator)
      inbox = create(:inbox, account: store)
      neighbors = [register('r202-1').last, create(:account, name: 'x-e2e-consent-r201-1'), create(:account, name: 'E2E-consent-r201-1')]
      revoked = []
      allow(Toybaco::PostizSync).to receive(:revoke_membership!) do |**arguments|
        revoked << [arguments[:user_id], arguments[:account].id]
        :revoked
      end
      expect(run!('e2e_purge_accounts', 'e2e-consent-r201-')).to eq(['TOYBACO_E2E_PURGE prefix=e2e-consent-r201- accounts=2 users=2 skipped_users=0'])
      expect([store, other_store, inbox].map { |record| record.class.exists?(record.id) }).to eq([false, false, false])
      expect(User.where(id: [owner, other_owner, staff, admin].map(&:id)).pluck(:id)).to contain_exactly(staff.id, admin.id)
      expect(AccountUser.where(user_id: [staff, admin].map(&:id)).pluck(:account_id)).to eq([kept_account.id])
      expect(Account.where(id: [kept_account, *neighbors].map(&:id)).count).to eq(4)
      # Postiz は所属ごとの取り消し(所属が無くなった Postiz の利用者も無効になる)と店舗の無効化を、店舗が残っているうちに行う。
      expect(revoked).to contain_exactly([owner.id, store.id], [staff.id, store.id], [admin.id, store.id], [other_owner.id, other_store.id])
      expect(Toybaco::PostizSync).to have_received(:disable_account!).with(account: have_attributes(id: store.id))
    end

    it '所属と自動応答の bot を店舗が残っているうちに消し、commit 後に積まれた job を実行しても失敗せず孤児を残さない' do
      owner, store = register('r206-1')
      staff = create(:user, email: 'staff-r206@example.com', account: store, role: :agent)
      inbox = create(:inbox, account: store)
      bot = create(:agent_bot, account: store, outgoing_url: nil)
      create(:agent_bot_inbox, account: store, inbox: inbox, agent_bot: bot)
      installation = Toybaco::GrowthAutoInstallation.create!(account_id: store.id, inbox_id: inbox.id, bot_id: bot.id, actor_id: owner.id,
                                                             request_id: SecureRandom.uuid, epoch: SecureRandom.uuid, state: 'stopped')
      queue_adapter.enqueued_jobs.clear
      expect(run!('e2e_purge_accounts', 'e2e-consent-r206-1'))
        .to eq(['TOYBACO_E2E_PURGE prefix=e2e-consent-r206-1 accounts=1 users=1 skipped_users=0'])
      expect { perform_enqueued_jobs }.not_to raise_error
      expect([Account.exists?(store.id), User.exists?(owner.id), User.exists?(staff.id)]).to eq([false, false, true])
      expect([AccountUser, AgentBotInbox, AgentBot].map { |model| model.where(account_id: store.id).count }).to eq([0, 0, 0])
      expect(AccountUser.where(user_id: [owner.id, staff.id]).count).to eq(0)
      # 自動応答の設置記録は店舗を消しても残る(trial と同じく再発行を防ぐ記録)。店舗が残っているうちに無効化されている。
      expect(installation.reload.generation).to be > 1
    end

    it '店舗の契約者が E2E の利用者でないかほかの店舗にも所属すれば、店舗を消す前に abort して何も消さない' do
      owner, store = register('r207-1')
      create(:account_user, account: create(:account, name: '別の店舗'), user: owner, role: :agent)
      outsider, outsider_store = register('r207-2', email: 'owner-r207@example.com')
      expect(refusal('e2e_purge_accounts', 'e2e-consent-r207-1'))
        .to eq("account=#{store.id} の契約者 user=#{owner.id} が E2E の利用者でないか、ほかの店舗にも所属するため削除しません。")
      expect(refusal('e2e_purge_accounts', 'e2e-consent-r207-2'))
        .to eq("account=#{outsider_store.id} の契約者 user=#{outsider.id} が E2E の利用者でないか、ほかの店舗にも所属するため削除しません。")
      expect(Account.where(id: [store.id, outsider_store.id]).count).to eq(2)
      expect(User.where(id: [owner.id, outsider.id]).count).to eq(2)
      expect(AccountUser.where(account_id: [store.id, outsider_store.id]).count).to eq(2)
    end

    it '候補を選んだ後に契約者に別の店舗の所属が増えたら、ロックして読み直して店舗を消さずに abort する' do
      owner, store = register('r208-1')
      elsewhere = create(:account, name: '別の店舗')
      allow(described_class::Purge).to receive(:candidates).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap { create(:account_user, account: elsewhere, user: owner, role: :agent) }
      end
      expect(refusal('e2e_purge_accounts', 'e2e-consent-r208-1'))
        .to eq("account=#{store.id} の契約者 user=#{owner.id} が E2E の利用者でないか、ほかの店舗にも所属するため削除しません。")
      expect([Account.exists?(store.id), User.exists?(owner.id)]).to eq([true, true])
      expect(AccountUser.where(user_id: owner.id).pluck(:account_id)).to contain_exactly(store.id, elsewhere.id)
    end

    it '候補を選んだ後に契約者以外の利用者に別の店舗の所属が増えたら、その利用者は消さずに数え、ほかの削除は進める' do
      owner, store = register('r209-1')
      member = create(:user, email: 'qa+e2e-consent-r209-member@example.com', account: store, role: :agent)
      elsewhere = create(:account, name: '別の店舗')
      allow(described_class::Purge).to receive(:candidates).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap { create(:account_user, account: elsewhere, user: member, role: :agent) }
      end
      expect(run!('e2e_purge_accounts', 'e2e-consent-r209-1'))
        .to eq(['TOYBACO_E2E_PURGE prefix=e2e-consent-r209-1 accounts=1 users=1 skipped_users=1'])
      expect([Account.exists?(store.id), User.exists?(owner.id), User.exists?(member.id)]).to eq([false, false, true])
      expect(AccountUser.where(user_id: member.id).pluck(:account_id)).to eq([elsewhere.id])
    end

    it 'prefix に一致した店舗に E2E の店舗名の形(e2e-consent-r<run>-<attempt>)でないもの(別の名前・後ろに続きがある名前)があれば、1 件も消さずに abort する' do
      owner, store = register('r210-1')
      others = [create(:account, name: 'e2e-consent-registration'), create(:account, name: 'e2e-consent-r210-2-old')]
      expect(refusal('e2e_purge_accounts', 'e2e-consent-r'))
        .to eq('prefix=e2e-consent-r に一致する店舗に、E2E の店舗名の形(e2e-consent-r<run>-<attempt>)でない店舗が 2 件あるため削除しません。')
      expect([Account.where(id: [store.id, *others.map(&:id)]).count, User.exists?(owner.id)]).to eq([3, true])
    end

    it '一致する店舗が無ければ何も消さずに 0 件を出す(後片付けの再実行も正常に終わり、監査行は ok)' do
      _, store = register('r203-1')
      expect(run!('e2e_purge_accounts', 'e2e-consent-r203-1'))
        .to eq(['TOYBACO_E2E_PURGE prefix=e2e-consent-r203-1 accounts=1 users=1 skipped_users=0'])
      expect(run!('e2e_purge_accounts', 'e2e-consent-r203-1'))
        .to eq(['TOYBACO_E2E_PURGE prefix=e2e-consent-r203-1 accounts=0 users=0 skipped_users=0'])
      expect(Account.exists?(store.id)).to be(false)
      expect(new_rows.pluck(:action, :result)).to eq([%w[rake.toybaco:e2e_purge_accounts started], %w[rake.toybaco:e2e_purge_accounts ok]] * 2)
    end

    it '一致する店舗が上限の 5 件を超えれば何も消さずに abort し、5 件ちょうどなら消す' do
      stores = (1..6).map { |index| create(:account, name: "e2e-consent-r231-#{index}") }
      expect(refusal('e2e_purge_accounts', 'e2e-consent-r231-'))
        .to eq('prefix=e2e-consent-r231- に一致する店舗が 6 件あり、1 回の上限 5 件を超えるため削除しません。prefix を絞ってください。')
      expect(Account.where(id: stores.map(&:id)).count).to eq(6)
      stores.last.update!(name: 'e2e-consent-r232-6')
      expect(run!('e2e_purge_accounts', 'e2e-consent-r231-')).to eq(['TOYBACO_E2E_PURGE prefix=e2e-consent-r231- accounts=5 users=0 skipped_users=0'])
      expect(Account.where(id: stores.map(&:id)).pluck(:id)).to eq([stores.last.id])
    end

    it 'production と環境が不明なときは、引数を読む前に abort して何も消さない' do
      owner, store = register('r204-1')
      [{ TOYBACO_DEPLOYMENT_ENVIRONMENT: 'production' }, { TOYBACO_DEPLOYMENT_ENVIRONMENT: nil },
       { TOYBACO_DEPLOYMENT_ENVIRONMENT: 'Staging' }].each do |env|
        with_modified_env(env) do
          expect(refusal('e2e_purge_accounts', 'e2e-consent-r204-1')).to eq("e2e_purge_accounts #{staging_only}")
          expect(refusal('e2e_purge_accounts', '%')).to eq("e2e_purge_accounts #{staging_only}")
        end
      end
      expect([Account.exists?(store.id), User.exists?(owner.id)]).to eq([true, true])
      expect(new_rows.pluck(:result)).to eq(%w[started failed] * 6)
    end

    it 'prefix が e2e-consent- の形でないか余分な引数があれば、入力を出さずに abort して何も消さない' do
      _, store = register('r299-1')
      invalid_prefixes.each { |value| expect(refusal('e2e_purge_accounts', value)).to eq(prefix_error) }
      expect(refusal('e2e_purge_accounts', 'e2e-consent-r299-1', 'x')).to eq('引数は prefix の 1 つだけを指定してください。')
      expect(Account.exists?(store.id)).to be(true)
    end

    it '削除を読み直して店舗が残っていれば abort し、所属と利用者の削除も取り消す' do
      owner, store = register('r205-1')
      allow(Account).to receive(:exists?).and_call_original
      allow(Account).to receive(:exists?).with(id: [store.id]).and_return(true)
      expect(refusal('e2e_purge_accounts', 'e2e-consent-r205-1'))
        .to eq('prefix=e2e-consent-r205-1 の削除を読み直すと店舗・利用者・所属・bot が残っているため、削除を取り消します。')
      expect([Account.where(id: store.id).count, User.where(id: owner.id).count, AccountUser.where(account_id: store.id).count]).to eq([1, 1, 1])
      expect(new_rows.pluck(:result)).to eq(%w[started failed])
    end
  end
end
