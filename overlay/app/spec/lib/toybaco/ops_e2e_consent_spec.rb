# frozen_string_literal: true

require 'rails_helper'
require 'active_support/testing/stream'

Rails.application.load_tasks unless Rake::Task.task_defined?('toybaco:legal_consents_by_name')

# staging の E2E(規約同意の記録の経路の確認)用の運営 rake(toybaco:legal_consents_by_name / e2e_confirm_user / e2e_purge_accounts)。
# 読み取りの行の形とメールアドレス・氏名を出さないこと、書き込みの 2 本が staging 以外で引数を読む前に abort すること、e2e-consent- の形と
# 書き込みの 2 本が扱う店舗名の厳格な形(e2e-consent-r<run>-<attempt>)の検査、選んだ後の名前・段階の変化(行ロックして読み直す。削除は
# 先頭 5 件の外の一致した店舗も)、確認と選んだ店舗だけの有効化(1 transaction)、削除の範囲(対象の店舗と、その店舗にだけ所属する E2E 用の
# 利用者と、所属が無くなった契約者。契約者が一致した店舗の外にも所属すれば削除しない。先頭 5 件の外の一致した店舗にも所属する利用者・契約者
# は消さずに数え、次の呼び出しで消す)と、確認の上限・削除の 1 回 5 件と残りの件数、commit 後にだけ送る job、削除の取り消し(rollback で
# job も残さない)を確かめる。削除は、消した店舗の体験(identity を含む)と自動応答の記録も消して件数を次の行に出し、E2E 以外の店舗の
# 同じ記録は残すことも確かめる。prefix の合成 id の開通の受付の記録(消した店舗に結んだものと店舗の無い失敗のもの)も消して件数を最後の行に
# 出し、E2E 以外の Session の受付と、消さない店舗に結んだ受付は残すことも確かめる。族の prefix(e2e-consent-r)で呼ぶと、前回までの複数の
# run の受付を合成 id の形(prefix の英数字の前方一致と厳格な形)で消し、Stripe の実 id の形の受付は残すことも確かめる。
# 別の接続の割り込みは、transactional fixtures の行が別の接続から見えないため、選んだ後に同じ接続で行を書き換えて表す(選んだ object は
# 古い値のまま)。
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

  # 削除の出力の 4 行(店舗・利用者の件数の行と、消した体験と自動応答の記録の件数の行と、消した課金の記録の件数の行と、消した開通の受付の記録の件数の行)。
  def purged(prefix, counts, growth = 'trials=0 identities=0 installations=0', opening = 'requests=0 events=0 notices=0',
             billing = 'events=0 requests=0 inflight=0')
    ["TOYBACO_E2E_PURGE prefix=#{prefix} #{counts}", "TOYBACO_E2E_PURGE_GROWTH prefix=#{prefix} #{growth}",
     "TOYBACO_E2E_PURGE_BILLING prefix=#{prefix} #{billing}", "TOYBACO_E2E_PURGE_OPENING prefix=#{prefix} #{opening}"]
  end

  # 開通の受付(toybaco_opening_requests)と、それに結んだ event(toybaco_billing_events)を作る。店舗に結ぶときは account_ready の形にする。
  def opening_request(session_id, event_id, account: nil, owner: nil)
    request = Toybaco::OpeningRequest.create!(mode: 'test', session_id: session_id, deadline_at: 1.day.from_now)
    if account
      request.update!(state: 'account_ready', account_id: account.id, owner_id: owner.id, subscription_id: "sub_#{event_id.delete_prefix('evt_')}",
                      contract_digest: 'fixture', account_ready_at: Time.now.utc)
    end
    Toybaco::BillingEvent.create!(event_id: event_id, mode: 'test', action: 'opening_checkout', reference_id: session_id,
                                  snapshot: { 'id' => event_id }, payload_digest: 'fixture', next_attempt_at: Time.now.utc,
                                  deadline_at: 1.day.from_now, opening_request_id: request.id)
    request
  end

  # 店舗に FK を持たない体験(identity を含む)と自動応答の記録(設置・切り替え・要求)を 1 組ずつ作り、id を返す。
  def growth_records(account)
    trial = Toybaco::GrowthTrial.create!(account_id: account.id, facts_revision: 'fixture', example_id: 1, starts_at: Time.now.utc,
                                         ends_at: 14.days.from_now)
    identity = trial.identities.create!(provider: 'imap', identity_digest: SecureRandom.hex(32))
    { trial: trial.id, identity: identity.id }.merge(auto_records(account))
  end

  # 設置の bot と受信箱は実在しない id にする(bot の削除の検査に当たらない)。要求は終わった状態(cancelled)にする。
  def auto_records(account)
    installation = Toybaco::GrowthAutoInstallation.create!(account_id: account.id, inbox_id: 900_000 + account.id, bot_id: 900_000 + account.id,
                                                           actor_id: 1, request_id: SecureRandom.uuid, epoch: SecureRandom.uuid, state: 'stopped')
    command = Toybaco::GrowthAutoCommand.create!(account_id: account.id, installation_id: installation.id, actor_id: 1,
                                                 request_id: SecureRandom.uuid, request_hash: 'fixture')
    request = Toybaco::GrowthAutoRequest.create!(account_id: account.id, inbox_id: installation.inbox_id, installation_id: installation.id,
                                                 generation: 1, epoch: installation.epoch, message_id: 1, conversation_id: 1,
                                                 enqueue_after: Time.now.utc, state: 'cancelled', terminal_at: Time.now.utc)
    { installation: installation.id, command: command.id, request: request.id }
  end

  def growth_counts(ids)
    [Toybaco::GrowthTrial.where(id: ids[:trial]), Toybaco::GrowthTrialIdentity.where(id: ids[:identity]),
     Toybaco::GrowthAutoInstallation.where(id: ids[:installation]), Toybaco::GrowthAutoCommand.where(id: ids[:command]),
     Toybaco::GrowthAutoRequest.where(id: ids[:request])].map(&:count)
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

    it '選んだ後に店舗の名前が E2E の形から変われば、行ロックして読み直して確認せずに abort する' do
      user, account = register('r118-1')
      allow(described_class).to receive(:accounts).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap { Account.find(account.id).update!(name: '本番の店舗') }
      end
      expect(refusal('e2e_confirm_user', 'e2e-consent-r118-1')).to eq("account=#{account.id} の名前か状態が選んだ後に変わったため確認しません。")
      # 確認は選ぶところから 1 つの transaction の中なので、この書き換えも abort で取り消される。確認と有効化は残らない。
      expect([user.reload.confirmed?, account.reload.status, phase(account)]).to eq([false, 'suspended', 'email_pending'])
    end

    it '選んだ後にメール確認待ちでなくなれば(確認メールのリンクで先に有効になったなど)、行ロックして読み直して確認せずに abort する' do
      user, account = register('r119-1')
      allow(described_class).to receive(:accounts).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap do
          fresh = Account.find(account.id)
          state = fresh.internal_attributes.deep_dup
          state['toybaco_growth_registration']['phase'] = 'active'
          fresh.update!(internal_attributes: state)
        end
      end
      expect(refusal('e2e_confirm_user', 'e2e-consent-r119-1')).to eq("account=#{account.id} の名前か状態が選んだ後に変わったため確認しません。")
      expect([user.reload.confirmed?, account.reload.status]).to eq([false, 'suspended'])
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
      queue_adapter.enqueued_jobs.clear
      expect { capture(:stdout) { run_task('e2e_confirm_user', 'e2e-consent-r116-') } }
        .to raise_error(ActiveRecord::ActiveRecordError, 'activation failed')
      # 確認と有効化は job を積まない(取り消した後に動く job が残らない)。積むようになれば削除と同じく commit の後に送る必要がある。
      expect(queue_adapter.enqueued_jobs).to eq([])
      expect([first_user.reload.confirmed?, second_user.reload.confirmed?]).to eq([false, false])
      expect([first.reload.status, phase(first), phase(second)]).to eq(%w[suspended email_pending email_pending])
      expect(new_rows.pluck(:result)).to eq(%w[started failed])
    end
  end

  # 確認 token は秘密として扱う。全ての例で、出力・abort の文(と監査行)に token の生値が無いことを確かめる。例の名前にも値を書かない。
  describe 'toybaco:e2e_confirmation_token' do
    let(:token) { SecureRandom.hex(32) }
    let(:token_error) { 'token は英小文字の 16 進数 64 桁で指定してください。' }
    let(:token_columns) { %w[confirmation_token confirmation_sent_at confirmed_at unconfirmed_email updated_at] }

    # 成功するはずの呼び出し。想定外の abort は、引数(token)を出さずにこの例の失敗に置き換える。
    def assign!(prefix, value = token)
      capture(:stdout) { run_task('e2e_confirmation_token', prefix, value) }.lines(chomp: true)
    rescue SystemExit
      raise RSpec::Expectations::ExpectationNotMetError, 'toybaco:e2e_confirmation_token が abort しました'
    end

    # 非 0 で abort することと標準出力が空であることを確かめ、abort の文(標準エラー)を返す。失敗の表示にも出力を載せない。
    def token_refusal(*values)
      status = nil
      message = nil
      printed = capture(:stdout) do
        message = capture(:stderr) do
          run_task('e2e_confirmation_token', *values)
        rescue SystemExit => e
          status = e.status
        end
      end
      expect(printed.empty?).to be(true), '拒否のときに標準出力へ何か出ています'
      expect(status).to eq(1)
      message.chomp
    end

    def expect_no_token(text, *values)
      values.each { |value| expect(text.include?(value)).to be(false), 'token の生値が出力・abort の文・監査行に含まれています' }
    end

    def token_state(users)
      users.map { |user| user.reload.attributes.slice(*token_columns) }
    end

    def assigned(prefix, user, account)
      "TOYBACO_E2E_CONFIRMATION_TOKEN prefix=#{prefix} user=#{user.id} account=#{account.id} phase=email_pending result=set"
    end

    def refused(prefix, account, reason)
      "TOYBACO_E2E_CONFIRMATION_TOKEN prefix=#{prefix} result=refused account=#{account&.id || '-'} reason=#{reason}"
    end

    def store_state(accounts)
      accounts.map { |account| [account.reload.status, phase(account)] }
    end

    # 拒否の 1 行で abort し、利用者の確認 token・送信時刻・確認・updated_at と店舗の段階が変わらず、監査行が started / failed であること。
    def expect_refused(prefix, expected, users, accounts = [])
      saved = [token_state(users), store_state(accounts)]
      message = token_refusal(prefix, token)
      expect(message).to eq(expected)
      expect([token_state(users), store_state(accounts)]).to eq(saved)
      expect(new_rows.last(2).pluck(:result)).to eq(%w[started failed])
      expect_no_token(message, token)
    end

    it 'staging で、prefix に一致するメール確認待ちの店舗の未確認の契約者に token を生値で書き、送信時刻を今にし、id と段階だけを 1 行で出す' do
      user, account = register('r301-1')
      neighbor, = register('r301-2')
      saved = token_state([user, neighbor])
      queue_adapter.enqueued_jobs.clear
      lines = assign!('e2e-consent-r301-1')
      expect(lines).to eq([assigned('e2e-consent-r301-1', user, account)])
      # 確認の HTTP 経路(DeviseOverrides::ConfirmationsController#create)と同じ、生値の一致で利用者を引ける。callback を通さないので
      # updated_at は変わらず、確認もメールの送信(job)もしない。
      expect([User.find_by(confirmation_token: token), user.reload.confirmation_sent_at]).to match([user, be_within(5.seconds).of(Time.now.utc)])
      kept = %w[confirmed_at unconfirmed_email updated_at]
      expect(token_state([user]).first.slice(*kept)).to eq(saved.first.slice(*kept))
      expect([token_state([neighbor]), queue_adapter.enqueued_jobs]).to eq([[saved.last], []])
      expect([user.confirmed?, account.reload.status, phase(account)]).to eq([false, 'suspended', 'email_pending'])
      expect_no_token(lines.join("\n"), token)
    end

    it '監査行に started と ok が残り、params_digest は prefix と token の canonical JSON の digest で、監査行と audit_tail に token の生値は無い' do
      register('r302-1')
      lines = assign!('e2e-consent-r302-1')
      digest = Toybaco::Ops::Audit.params_digest({ 'prefix' => 'e2e-consent-r302-1', 'token' => token })
      expect(new_rows.pluck(:action, :result, :params_digest)).to eq(
        [['rake.toybaco:e2e_confirmation_token', 'started', digest], ['rake.toybaco:e2e_confirmation_token', 'ok', digest]]
      )
      expect(digest).not_to eq(Toybaco::Ops::Audit.params_digest({ 'prefix' => 'e2e-consent-r302-1' }))
      audit_text = new_rows.map { |row| row.attributes.values.join(' ') }.join("\n")
      expect_no_token([lines, audit_text, run!('audit_tail', '5')].join("\n"), token)
    end

    it 'もう一度呼べば新しい token で上書きし(result=set)、前の token では利用者を引けない' do
      user, account = register('r303-1')
      previous = SecureRandom.hex(32)
      lines = assign!('e2e-consent-r303-1', previous) + assign!('e2e-consent-r303-1')
      expect(lines).to eq([assigned('e2e-consent-r303-1', user, account)] * 2)
      expect([User.find_by(confirmation_token: previous), User.find_by(confirmation_token: token)]).to eq([nil, user])
      expect([user.reload.confirmation_token == token, user.confirmed?]).to eq([true, false])
      expect(new_rows.pluck(:result)).to eq(%w[started ok] * 2)
      expect_no_token(lines.join("\n"), previous, token)
    end

    it '設定した token は確認の HTTP 経路と同じ引き方と User#confirm で確認でき(期限内)、確認の commit 後の処理で店舗が有効になる' do
      user, account = register('r304-1')
      lines = assign!('e2e-consent-r304-1')
      expect(User.find_by(confirmation_token: token)&.confirm).to be(true)
      expect([user.reload.confirmed?, account.reload.status, phase(account)]).to eq([true, 'active', 'active'])
      expect(run!('e2e_registration_phase', 'e2e-consent-r304-1').first)
        .to eq("TOYBACO_E2E_REGISTRATION user=#{user.id} account=#{account.id} phase=active confirmed=true")
      expect_no_token(lines.join("\n"), token)
    end

    it 'production と環境が不明なときは、引数を読む前に abort して token を書かない' do
      user, = register('r311-1')
      saved = token_state([user])
      allow(described_class::Confirmation).to receive(:confirmation_arguments!).and_call_original
      messages = [{ TOYBACO_DEPLOYMENT_ENVIRONMENT: 'production' }, { TOYBACO_DEPLOYMENT_ENVIRONMENT: nil },
                  { TOYBACO_DEPLOYMENT_ENVIRONMENT: 'Staging' }].flat_map do |env|
        with_modified_env(env) { [token_refusal('e2e-consent-r311-1', token), token_refusal('%', 'A' * 63)] }
      end
      expect(messages.uniq).to eq(["e2e_confirmation_token #{staging_only}"])
      expect(described_class::Confirmation).not_to have_received(:confirmation_arguments!)
      expect([token_state([user]), new_rows.pluck(:result)]).to eq([saved, %w[started failed] * 6])
      expect_no_token(messages.join("\n"), token)
    end

    it 'token が英小文字の 16 進数 64 桁でないか、prefix の形が違うか、余分な引数があれば、入力を出さずに abort して token を書かない' do
      user, = register('r312-1')
      saved = token_state([user])
      # 63 桁・65 桁・大文字・- を含む・16 進数でない字・前後の空白や改行・空・nil・Symbol。
      invalid = ['a' * 63, 'a' * 65, 'A' * 64, "#{'a' * 63}-", 'g' * 64, " #{'a' * 63}", "#{'a' * 64}\n", '', nil, :"#{'a' * 64}"]
      invalid.each do |value|
        message = token_refusal('e2e-consent-r312-1', value)
        expect(message).to eq(token_error)
        expect_no_token(message, value.to_s) unless value.to_s.empty?
      end
      invalid_prefixes.each { |value| expect(token_refusal(value, token)).to eq(prefix_error) }
      expect(token_refusal('e2e-consent-r312-1', token, 'x')).to eq('引数は prefix と token の 2 つだけを指定してください。')
      expect([token_state([user]), new_rows.pluck(:result)]).to eq([saved, %w[started failed] * (invalid.size + invalid_prefixes.size + 1)])
    end

    it 'prefix に一致する店舗が無ければ no_account、2 件以上なら multiple_accounts で abort し、どの利用者にも書かない' do
      first, first_store = register('r321-1')
      second, second_store = register('r321-2')
      expect_refused('e2e-consent-r320-', refused('e2e-consent-r320-', nil, 'no_account'), [first, second])
      expect_refused('e2e-consent-r321-', refused('e2e-consent-r321-', nil, 'multiple_accounts'), [first, second], [first_store, second_store])
    end

    it '契約者が確認済みなら already_confirmed で abort して書かない' do
      user, account = register('r322-1')
      # callback を通さずに確認済みにする(店舗はメール確認待ちのまま。確認の commit 後の処理が失敗した状態に当たる)。
      user.update_columns(confirmed_at: 1.hour.ago) # rubocop:disable Rails/SkipsModelValidations
      expect_refused('e2e-consent-r322-1', refused('e2e-consent-r322-1', account, 'already_confirmed'), [user], [account])
    end

    it '店舗がメール確認待ちでなければ(段階が active)not_email_pending で abort して書かない' do
      user, account = register('r323-1')
      state = account.internal_attributes.deep_dup
      state['toybaco_growth_registration']['phase'] = 'active'
      account.update!(internal_attributes: state)
      expect_refused('e2e-consent-r323-1', refused('e2e-consent-r323-1', account, 'not_email_pending'), [user], [account])
    end

    it '契約者がメールアドレスの変更の再確認待ち(unconfirmed_email あり)なら unconfirmed_email で abort して書かない' do
      user, account = register('r324-1')
      user.update_columns(unconfirmed_email: 'qa+e2e-consent-r324-2@example.com') # rubocop:disable Rails/SkipsModelValidations
      expect_refused('e2e-consent-r324-1', refused('e2e-consent-r324-1', account, 'unconfirmed_email'), [user], [account])
    end

    it '同じ token を持つ別の利用者がいれば token_in_use で abort し、どちらの利用者にも書かない' do
      user, account = register('r325-1')
      other, = register('r326-1')
      other.update_columns(confirmation_token: token) # rubocop:disable Rails/SkipsModelValidations
      expect_refused('e2e-consent-r325-1', refused('e2e-consent-r325-1', account, 'token_in_use'), [user, other], [account])
      expect(User.where(confirmation_token: token).pluck(:id)).to eq([other.id])
    end

    it '契約者が E2E 用のメールアドレスでないか、E2E の店舗の外にも所属すれば not_e2e_user で abort して書かない' do
      outsider, outsider_store = register('r327-1', email: 'owner-r327@example.com')
      shared, shared_store = register('r328-1')
      create(:account_user, account: create(:account, name: '本番の店舗'), user: shared, role: :agent)
      expect_refused('e2e-consent-r327-1', refused('e2e-consent-r327-1', outsider_store, 'not_e2e_user'), [outsider, shared], [outsider_store])
      expect_refused('e2e-consent-r328-1', refused('e2e-consent-r328-1', shared_store, 'not_e2e_user'), [outsider, shared], [shared_store])
    end

    it '契約者が見つからなければ owner_missing、選んだ店舗の外にもメール確認待ちの店舗を持てば other_pending で abort して書かない' do
      broken = create(:account, name: 'e2e-consent-r329-1', internal_attributes: registration_state(0))
      user, account = register('r330-1')
      other = create(:account, name: 'e2e-consent-r930-1', internal_attributes: registration_state(user.id))
      create(:account_user, account: other, user: user, role: :administrator)
      expect_refused('e2e-consent-r329-1', refused('e2e-consent-r329-1', broken, 'owner_missing'), [user], [broken])
      expect_refused('e2e-consent-r330-1', refused('e2e-consent-r330-1', account, 'other_pending'), [user], [account, other])
    end

    it '契約者が名前だけ E2E 風の実店舗(run の店舗名の形でない・有効)にも所属すれば other_memberships で abort して書かない' do
      user, account = register('r334-1')
      real = create(:account, name: 'e2e-consent-registration', status: :active)
      create(:account_user, account: real, user: user, role: :agent)
      # e2e_user? は所属先の名前が e2e-consent- で始まれば通し、実店舗はメール確認待ちでもないため、所属の数で止める。
      expect(described_class.e2e_user?(user.reload)).to be(true)
      expect_refused('e2e-consent-r334-1', refused('e2e-consent-r334-1', account, 'other_memberships'), [user], [account, real])
      expect(AccountUser.where(user_id: user.id).pluck(:account_id)).to contain_exactly(account.id, real.id)
    end

    it 'prefix に一致した店舗に E2E の店舗名の形でないものがあれば、confirm と同じ文で abort して書かない' do
      user, account = register('r331-1')
      create(:account, name: 'e2e-consent-registration')
      expect_refused('e2e-consent-r', 'prefix=e2e-consent-r に一致する店舗に、E2E の店舗名の形(e2e-consent-r<run>-<attempt>)でない店舗が 1 件あるため' \
                                      '確認 token を設定しません。', [user], [account])
    end

    it '選んだ後に店舗の名前が E2E の形から変われば、行ロックして読み直して書かずに abort する' do
      user, account = register('r332-1')
      allow(described_class).to receive(:accounts).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap { Account.find(account.id).update!(name: '本番の店舗') }
      end
      expect_refused('e2e-consent-r332-1', "account=#{account.id} の名前か状態が選んだ後に変わったため確認 token を設定しません。", [user])
      # 選ぶところから 1 つの transaction の中なので、この書き換えも abort で取り消される。
      expect(account.reload.name).to eq('e2e-consent-r332-1')
    end

    it '選んだ後にメール確認待ちでなくなれば(確認メールのリンクで先に有効になったなど)、行ロックして読み直して書かずに abort する' do
      user, account = register('r333-1')
      allow(described_class).to receive(:accounts).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap do
          fresh = Account.find(account.id)
          state = fresh.internal_attributes.deep_dup
          state['toybaco_growth_registration']['phase'] = 'active'
          fresh.update!(internal_attributes: state)
        end
      end
      expect_refused('e2e-consent-r333-1', "account=#{account.id} の名前か状態が選んだ後に変わったため確認 token を設定しません。", [user], [account])
    end
  end

  describe 'toybaco:e2e_registration_phase' do
    # ブロックの中で、監査行(toybaco_operator_actions。RakeAudit が別の DB セッションで書く)の外へ書いた SQL。
    def writes_during(&)
      statements = []
      callback = ->(*, payload) { statements << payload[:sql].to_s }
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
      statements.grep(%r{\A\s*(?:/\*.*?\*/\s*)?(?:INSERT|UPDATE|DELETE)\b}im).grep_v(/toybaco_operator_actions/)
    end

    # 読み取りの実行。DB へ書かず(監査行のほか)、job も積まず、店舗と契約者の行も変えないことを確かめてから出力の行を返す。
    def read_phase(prefix, records)
      saved = records.map { |record| record.reload.attributes }
      queue_adapter.enqueued_jobs.clear
      lines = nil
      expect(writes_during { lines = run!('e2e_registration_phase', prefix) }).to eq([])
      expect([queue_adapter.enqueued_jobs, records.map { |record| record.reload.attributes }]).to eq([[], saved])
      lines
    end

    it 'staging で、一致する店舗ごとに契約者・段階・確認の有無を読み取りだけで出し、確認の後は phase=active confirmed=true になる' do
      user, account = register('r401-1')
      lines = read_phase('e2e-consent-r401-1', [user, account])
      expect(lines).to eq(["TOYBACO_E2E_REGISTRATION user=#{user.id} account=#{account.id} phase=email_pending confirmed=false",
                           'TOYBACO_E2E_REGISTRATION_SUMMARY prefix=e2e-consent-r401-1 accounts=1'])
      expect(user.reload.confirm).to be(true)
      confirmed = read_phase('e2e-consent-r401-1', [user, account])
      expect(confirmed.first).to eq("TOYBACO_E2E_REGISTRATION user=#{user.id} account=#{account.id} phase=active confirmed=true")
      expect((lines + confirmed).join("\n")).not_to include('@', 'qa+', user.name)
    end

    it '一致した店舗が 2 件なら id の順に 2 行を出し、無料登録の記録が無い店舗は user・phase・confirmed を - にする' do
      user, account = register('r402-1')
      plain = create(:account, name: 'e2e-consent-r402-2')
      lines = read_phase('e2e-consent-r402-', [user, account, plain])
      expect(lines).to eq(["TOYBACO_E2E_REGISTRATION user=#{user.id} account=#{account.id} phase=email_pending confirmed=false",
                           "TOYBACO_E2E_REGISTRATION user=- account=#{plain.id} phase=- confirmed=-",
                           'TOYBACO_E2E_REGISTRATION_SUMMARY prefix=e2e-consent-r402- accounts=2'])
      expect(lines.join("\n")).not_to include('@', 'qa+', user.name)
    end

    it '一致する店舗が無ければ店舗数 0 の 1 行だけを出して正常に終わり、監査行の params_digest は prefix の digest' do
      create(:account, name: 'e2e-consent-r499-1')
      expect(read_phase('e2e-consent-r403-', [])).to eq(['TOYBACO_E2E_REGISTRATION_SUMMARY prefix=e2e-consent-r403- accounts=0'])
      digest = Toybaco::Ops::Audit.params_digest({ 'prefix' => 'e2e-consent-r403-' })
      expect(new_rows.pluck(:action, :result, :params_digest)).to eq(
        [['rake.toybaco:e2e_registration_phase', 'started', digest], ['rake.toybaco:e2e_registration_phase', 'ok', digest]]
      )
    end

    it '読み取りなので E2E の店舗名の形でない店舗も出し、契約者が見つからなければ user と confirmed を -、形の違う段階は invalid と出す' do
      missing = create(:account, name: 'e2e-consent-registration', internal_attributes: registration_state(0))
      odd = create(:account, name: 'e2e-consent-r404-1',
                             internal_attributes: { 'toybaco_growth_registration' => { 'phase' => 'Active!', 'owner_id' => 'x' } })
      expect(read_phase('e2e-consent-r', [missing, odd])).to eq(
        ["TOYBACO_E2E_REGISTRATION user=- account=#{missing.id} phase=email_pending confirmed=-",
         "TOYBACO_E2E_REGISTRATION user=- account=#{odd.id} phase=invalid confirmed=-",
         'TOYBACO_E2E_REGISTRATION_SUMMARY prefix=e2e-consent-r accounts=2']
      )
    end

    it 'production と環境が不明なときは、引数を読む前に abort する' do
      register('r405-1')
      [{ TOYBACO_DEPLOYMENT_ENVIRONMENT: 'production' }, { TOYBACO_DEPLOYMENT_ENVIRONMENT: nil },
       { TOYBACO_DEPLOYMENT_ENVIRONMENT: 'Staging' }].each do |env|
        with_modified_env(env) do
          expect(refusal('e2e_registration_phase', 'e2e-consent-r405-1')).to eq("e2e_registration_phase #{staging_only}")
          expect(refusal('e2e_registration_phase', '%')).to eq("e2e_registration_phase #{staging_only}")
        end
      end
      expect(new_rows.pluck(:result)).to eq(%w[started failed] * 6)
    end

    it 'prefix が e2e-consent- の形でないか余分な引数があれば、入力を出さずに abort する' do
      invalid_prefixes.each { |value| expect(refusal('e2e_registration_phase', value)).to eq(prefix_error) }
      expect(refusal('e2e_registration_phase', 'e2e-consent-a', 'x')).to eq('引数は prefix の 1 つだけを指定してください。')
      expect(new_rows.pluck(:result)).to eq(%w[started failed] * (invalid_prefixes.size + 1))
    end
  end

  describe 'toybaco:e2e_invite_agent' do
    let(:token) { SecureRandom.hex(32) }
    let(:token_error) { 'token は英小文字の 16 進数 64 桁で指定してください。' }
    # PUT /auth/password(DeviseOverrides::PasswordsController#update)が受け取った生値から利用者を引くときの digest。
    let(:digest) { Devise.token_generator.digest(User, :reset_password_token, token) }

    # 無料登録の後に契約者を確認し(確認の commit 後の処理で店舗が有効になる)、招待できる店舗にする。
    def active_registration(run, email: "qa+e2e-consent-#{run}@example.com")
      owner, account = register(run, email: email)
      expect(owner.confirm).to be(true)
      expect([account.reload.status, phase(account)]).to eq(%w[active active])
      [owner.reload, account]
    end

    # 成功するはずの呼び出し。想定外の abort は、引数(token)を出さずにこの例の失敗に置き換える。
    def invite!(prefix, value = token)
      capture(:stdout) { run_task('e2e_invite_agent', prefix, value) }.lines(chomp: true)
    rescue SystemExit
      raise RSpec::Expectations::ExpectationNotMetError, 'toybaco:e2e_invite_agent が abort しました'
    end

    # 非 0 で abort することと標準出力が空であることを確かめ、abort の文(標準エラー)を返す。失敗の表示にも出力を載せない。
    def invite_refusal(*values)
      status = nil
      message = nil
      printed = capture(:stdout) do
        message = capture(:stderr) do
          run_task('e2e_invite_agent', *values)
        rescue SystemExit => e
          status = e.status
        end
      end
      expect(printed.empty?).to be(true), '拒否のときに標準出力へ何か出ています'
      expect(status).to eq(1)
      message.chomp
    end

    def expect_no_secret(text, *values)
      values.each { |value| expect(text.include?(value)).to be(false), 'token の生値か digest が出力・abort の文・監査行に含まれています' }
    end

    def invited(prefix, invitee, account, owner)
      "TOYBACO_E2E_INVITE prefix=#{prefix} user=#{invitee.id} account=#{account.id} owner=#{owner.id} result=invited"
    end

    def refused(prefix, account, reason)
      "TOYBACO_E2E_INVITE prefix=#{prefix} result=refused account=#{account&.id || '-'} reason=#{reason}"
    end

    def invitee_of(prefix)
      User.from_email("qa+#{prefix}-invite@example.com")
    end

    # 利用者と所属の数、関わる利用者・店舗の行(全ての列)。拒否で何も変わらないことを確かめる。
    def invite_state(records)
      [User.count, AccountUser.count, records.map { |record| record.reload.attributes }]
    end

    # 積まれたメールの送信の job(Devise の通知は deliver_later で ActionMailer::MailDeliveryJob を積む)。
    def mail_jobs
      queue_adapter.enqueued_jobs.select { |job| job[:job].is_a?(Class) && job[:job] <= ActionMailer::MailDeliveryJob }
    end

    # 拒否の 1 行で abort し、利用者・所属が増えず、関わる行が変わらず、監査行が started / failed であること。
    def expect_refused(prefix, expected, records)
      saved = invite_state(records)
      message = invite_refusal(prefix, token)
      expect(message).to eq(expected)
      expect(invite_state(records)).to eq(saved)
      expect(new_rows.last(2).pluck(:result)).to eq(%w[started failed])
      expect_no_secret(message, token, digest)
    end

    it 'staging で、有効な E2E の店舗に招待先を未確認の agent として作り、id だけを 1 行で出し、ほかの店舗と契約者は変えない' do
      owner, account = active_registration('r601-1')
      neighbors = active_registration('r601-2')
      counts = [User.count, AccountUser.count]
      saved = neighbors.map { |record| record.reload.attributes }
      lines = invite!('e2e-consent-r601-1')
      invitee = invitee_of('e2e-consent-r601-1')
      expect(lines).to eq([invited('e2e-consent-r601-1', invitee, account, owner)])
      # 招待先は契約者の受信箱の別の tag で、E2E 用のメールアドレスの形。未確認で、所属はこの店舗の agent 1 件だけ(招待した人は契約者)。
      expect(invitee.email).to eq('qa+e2e-consent-r601-1-invite@example.com').and match(described_class::EMAIL_FORMAT)
      expect([invitee.confirmed?, invitee.name, invitee.type, invitee.encrypted_password.present?]).to eq([false, 'E2E 招待 担当者', nil, true])
      expect(AccountUser.where(user_id: invitee.id).pluck(:account_id, :role, :inviter_id)).to eq([[account.id, 'agent', owner.id]])
      expect([owner.reload.confirmed?, account.reload.status, phase(account)]).to eq([true, 'active', 'active'])
      # 増えるのは招待先と、その所属の 1 件ずつだけ(隣の E2E の店舗と契約者は変えない)。
      expect([[User.count, AccountUser.count], neighbors.map { |record| record.reload.attributes }]).to eq([counts.map(&:succ), saved])
      expect(lines.join("\n")).not_to include('@', 'qa+', invitee.name, owner.name)
      expect_no_secret(lines.join("\n"), token, digest)
    end

    it '招待先の再設定 token は digest だけを置き(PUT /auth/password と同じ引き方で引ける)、送信時刻を今にし、メールを送らない' do
      active_registration('r603-1')
      ActionMailer::Base.deliveries.clear
      queue_adapter.enqueued_jobs.clear
      lines = invite!('e2e-consent-r603-1')
      invitee = invitee_of('e2e-consent-r603-1')
      # DB には digest だけを置き、受け取った生値の digest で招待先を引ける(生値では引けない)。失敗の表示に値を載せないよう真偽で比べる。
      expect([invitee.reset_password_token == digest, User.find_by(reset_password_token: digest)&.id == invitee.id]).to eq([true, true])
      expect([invitee.reset_password_token == token, User.exists?(reset_password_token: token)]).to eq([false, false])
      expect(invitee.reset_password_sent_at).to be_within(5.seconds).of(Time.now.utc)
      # 確認・招待・再設定のメールを送らない(即時の送信も、送信の job も無い)。job の引数(token を含む)は表示しない。
      expect([ActionMailer::Base.deliveries.size, mail_jobs.map { |job| job[:job].name }]).to eq([0, []])
      expect_no_secret(lines.join("\n"), token, digest)
    end

    it '監査行に started と ok が残り、params_digest は prefix と token の canonical JSON の digest で、監査行と audit_tail に token は無い' do
      active_registration('r602-1')
      lines = invite!('e2e-consent-r602-1')
      audit = Toybaco::Ops::Audit.params_digest({ 'prefix' => 'e2e-consent-r602-1', 'token' => token })
      expect(new_rows.pluck(:action, :result, :params_digest)).to eq(
        [['rake.toybaco:e2e_invite_agent', 'started', audit], ['rake.toybaco:e2e_invite_agent', 'ok', audit]]
      )
      audit_text = new_rows.map { |row| row.attributes.values.join(' ') }.join("\n")
      expect_no_secret([lines, audit_text, run!('audit_tail', '5')].join("\n"), token, digest)
    end

    it 'production と環境が不明なときは、引数を読む前に abort して招待しない' do
      owner, account = active_registration('r611-1')
      saved = invite_state([owner, account])
      allow(described_class::Confirmation).to receive(:confirmation_arguments!).and_call_original
      messages = [{ TOYBACO_DEPLOYMENT_ENVIRONMENT: 'production' }, { TOYBACO_DEPLOYMENT_ENVIRONMENT: nil },
                  { TOYBACO_DEPLOYMENT_ENVIRONMENT: 'Staging' }].flat_map do |env|
        with_modified_env(env) { [invite_refusal('e2e-consent-r611-1', token), invite_refusal('%', 'A' * 63)] }
      end
      expect(messages.uniq).to eq(["e2e_invite_agent #{staging_only}"])
      expect(described_class::Confirmation).not_to have_received(:confirmation_arguments!)
      expect([invite_state([owner, account]), new_rows.pluck(:result)]).to eq([saved, %w[started failed] * 6])
      expect_no_secret(messages.join("\n"), token, digest)
    end

    it 'token が英小文字の 16 進数 64 桁でないか、prefix の形が違うか、余分な引数があれば、入力を出さずに abort して招待しない' do
      owner, account = active_registration('r612-1')
      saved = invite_state([owner, account])
      # 63 桁・65 桁・大文字・- を含む・16 進数でない字・前後の空白や改行・空・nil・Symbol。
      invalid = ['a' * 63, 'a' * 65, 'A' * 64, "#{'a' * 63}-", 'g' * 64, " #{'a' * 63}", "#{'a' * 64}\n", '', nil, :"#{'a' * 64}"]
      invalid.each do |value|
        message = invite_refusal('e2e-consent-r612-1', value)
        expect(message).to eq(token_error)
        expect_no_secret(message, value.to_s) unless value.to_s.empty?
      end
      invalid_prefixes.each { |value| expect(invite_refusal(value, token)).to eq(prefix_error) }
      expect(invite_refusal('e2e-consent-r612-1', token, 'x')).to eq('引数は prefix と token の 2 つだけを指定してください。')
      expect([invite_state([owner, account]), new_rows.pluck(:result)])
        .to eq([saved, %w[started failed] * (invalid.size + invalid_prefixes.size + 1)])
    end

    it 'prefix に一致する店舗が無ければ no_account、2 件以上なら multiple_accounts で abort し、誰も招待しない' do
      first, first_store = active_registration('r621-1')
      second, second_store = active_registration('r621-2')
      records = [first, first_store, second, second_store]
      expect_refused('e2e-consent-r620-', refused('e2e-consent-r620-', nil, 'no_account'), records)
      expect_refused('e2e-consent-r621-', refused('e2e-consent-r621-', nil, 'multiple_accounts'), records)
    end

    it '店舗がメール確認待ち(契約者の確認の前)なら not_active で abort して招待しない' do
      owner, account = register('r622-1')
      expect_refused('e2e-consent-r622-1', refused('e2e-consent-r622-1', account, 'not_active'), [owner, account])
    end

    it '契約者が未確認なら not_confirmed、メールアドレスの変更の再確認待ちなら unconfirmed_email で abort して招待しない' do
      owner, account = active_registration('r623-1')
      waiting, waiting_store = active_registration('r623-2')
      # callback を通さずに未確認に戻す(店舗は有効のまま)・再確認待ちにする。
      owner.update_columns(confirmed_at: nil) # rubocop:disable Rails/SkipsModelValidations
      waiting.update_columns(unconfirmed_email: 'qa+e2e-consent-r623-3@example.com') # rubocop:disable Rails/SkipsModelValidations
      expect_refused('e2e-consent-r623-1', refused('e2e-consent-r623-1', account, 'not_confirmed'), [owner, account])
      expect_refused('e2e-consent-r623-2', refused('e2e-consent-r623-2', waiting_store, 'unconfirmed_email'), [waiting, waiting_store])
    end

    it '契約者が名前だけ E2E 風の実店舗(run の店舗名の形でない・有効)にも所属すれば other_memberships で abort して招待しない' do
      owner, account = active_registration('r624-1')
      real = create(:account, name: 'e2e-consent-registration', status: :active)
      create(:account_user, account: real, user: owner, role: :agent)
      expect(described_class.e2e_user?(owner.reload)).to be(true)
      expect_refused('e2e-consent-r624-1', refused('e2e-consent-r624-1', account, 'other_memberships'), [owner, account, real])
    end

    it '契約者が E2E 用のメールアドレスでなければ not_e2e_user、見つからなければ owner_missing、ほかにメール確認待ちの店舗を持てば other_pending' do
      outsider, outsider_store = active_registration('r625-1', email: 'owner-r625@example.com')
      broken = create(:account, name: 'e2e-consent-r626-1',
                                internal_attributes: { 'toybaco_growth_registration' => { 'phase' => 'active', 'owner_id' => 0 } })
      owner, account = active_registration('r627-1')
      pending = create(:account, name: 'e2e-consent-r927-1', internal_attributes: registration_state(owner.id))
      create(:account_user, account: pending, user: owner, role: :administrator)
      expect_refused('e2e-consent-r625-1', refused('e2e-consent-r625-1', outsider_store, 'not_e2e_user'), [outsider, outsider_store])
      expect_refused('e2e-consent-r626-1', refused('e2e-consent-r626-1', broken, 'owner_missing'), [broken])
      expect_refused('e2e-consent-r627-1', refused('e2e-consent-r627-1', account, 'other_pending'), [owner, account, pending])
    end

    it '招待先と同じメールアドレスの利用者が既にいれば(前の run の残り・同じ prefix の 2 回目)invitee_exists で abort し、その利用者に触れない' do
      owner, account = active_registration('r628-1')
      leftover = create(:user, email: 'qa+e2e-consent-r628-1-invite@example.com', name: '前の招待先')
      expect_refused('e2e-consent-r628-1', refused('e2e-consent-r628-1', account, 'invitee_exists'), [owner, account, leftover])
      expect(AccountUser.where(user_id: leftover.id)).to be_empty
      second_owner, second_store = active_registration('r629-1')
      invite!('e2e-consent-r629-1')
      invitee = invitee_of('e2e-consent-r629-1')
      expect_refused('e2e-consent-r629-1', refused('e2e-consent-r629-1', second_store, 'invitee_exists'), [second_owner, second_store, invitee])
      expect([invitee.reload.reset_password_token == digest, AccountUser.where(user_id: invitee.id).count]).to eq([true, 1])
    end

    it '契約者のメールアドレスが受信箱の plus addressing の形でなければ(local 部が e2e-consent-<tag>)invite_email_format で abort して招待しない' do
      owner, account = active_registration('r630-1', email: 'e2e-consent-r630-1@example.com')
      expect(described_class.e2e_user?(owner)).to be(true)
      expect_refused('e2e-consent-r630-1', refused('e2e-consent-r630-1', account, 'invite_email_format'), [owner, account])
      expect(User.exists?(email: 'e2e-consent-r630-1-invite@example.com')).to be(false)
    end

    it 'prefix に一致した店舗に E2E の店舗名の形でないものがあれば、confirm と同じ文で abort して招待しない' do
      owner, account = active_registration('r631-1')
      create(:account, name: 'e2e-consent-registration')
      expect_refused('e2e-consent-r', 'prefix=e2e-consent-r に一致する店舗に、E2E の店舗名の形(e2e-consent-r<run>-<attempt>)でない店舗が 1 件あるため' \
                                      '担当者を招待しません。', [owner, account])
    end

    it '選んだ後に店舗が有効でなくなれば、行ロックして読み直して招待せずに abort する' do
      owner, account = active_registration('r632-1')
      allow(described_class).to receive(:accounts).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap do
          fresh = Account.find(account.id)
          state = fresh.internal_attributes.deep_dup
          state['toybaco_growth_registration']['phase'] = 'email_pending'
          fresh.update!(internal_attributes: state)
        end
      end
      expect_refused('e2e-consent-r632-1', "account=#{account.id} の名前か状態が選んだ後に変わったため担当者を招待しません。", [owner, account])
      # 選ぶところから 1 つの transaction の中なので、この書き換えも abort で取り消される。
      expect(phase(account)).to eq('active')
    end

    it '招待の後の e2e_purge_accounts は、招待先を契約者と一緒に消す(users=2)' do
      owner, account = active_registration('r633-1')
      invite!('e2e-consent-r633-1')
      invitee = invitee_of('e2e-consent-r633-1')
      expect(run!('e2e_purge_accounts', 'e2e-consent-r633-1'))
        .to eq(purged('e2e-consent-r633-1', 'accounts=1 users=2 skipped_users=0 remaining=0'))
      expect([Account.exists?(account.id), User.exists?(owner.id), User.exists?(invitee.id)]).to eq([false, false, false])
      expect(AccountUser.where(user_id: [owner.id, invitee.id])).to be_empty
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
      expect(run!('e2e_purge_accounts', 'e2e-consent-r201-'))
        .to eq(purged('e2e-consent-r201-', 'accounts=2 users=2 skipped_users=0 remaining=0'))
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
      invalidated = []
      allow(Toybaco::Growth::ManagedAuto).to receive(:invalidate!).and_wrap_original do |original, account_id, **options|
        invalidated << [account_id, Account.exists?(account_id)]
        original.call(account_id, **options)
      end
      queue_adapter.enqueued_jobs.clear
      expect(run!('e2e_purge_accounts', 'e2e-consent-r206-1'))
        .to eq(purged('e2e-consent-r206-1', 'accounts=1 users=1 skipped_users=0 remaining=0', 'trials=0 identities=0 installations=1'))
      # 所属の削除の後始末(Agents::DestroyJob)は transaction の中で積まれ、commit の後に送られる(owner と staff の 2 件)。
      expect(Agents::DestroyJob).to have_been_enqueued.exactly(2).times
      expect { perform_enqueued_jobs }.not_to raise_error
      expect([Account.exists?(store.id), User.exists?(owner.id), User.exists?(staff.id)]).to eq([false, false, true])
      expect([AccountUser, AgentBotInbox, AgentBot].map { |model| model.where(account_id: store.id).count }).to eq([0, 0, 0])
      expect(AccountUser.where(user_id: [owner.id, staff.id]).count).to eq(0)
      # 自動応答の設置記録は、店舗が残っているうちに無効化され(割り当て・bot・店舗の削除の検査)、店舗を消した後に E2E の店舗の分として消える。
      expect([invalidated.uniq, Toybaco::GrowthAutoInstallation.exists?(installation.id)]).to eq([[[store.id, true]], false])
    end

    it '店舗を消した後に、E2E の店舗の体験(identity を含む)と自動応答の記録(設置・切り替え・要求)を消して件数を次の行に出し、E2E 以外の店舗の同じ記録は残す' do
      _, store = register('r241-1')
      kept_store = create(:account, name: '残す店舗')
      ids = [store, kept_store].index_with { |account| growth_records(account) }
      expect(run!('e2e_purge_accounts', 'e2e-consent-r241-1'))
        .to eq(purged('e2e-consent-r241-1', 'accounts=1 users=1 skipped_users=0 remaining=0', 'trials=1 identities=1 installations=1'))
      expect(growth_counts(ids.fetch(store))).to eq([0, 0, 0, 0, 0])
      expect(growth_counts(ids.fetch(kept_store))).to eq([1, 1, 1, 1, 1])
      expect([Account.exists?(store.id), Account.exists?(kept_store.id)]).to eq([false, true])
    end

    it '体験と自動応答の記録が無い店舗だけを消すときも、件数 0 の行を出す(一致が 0 件の再実行も同じ)' do
      register('r242-1')
      expect(run!('e2e_purge_accounts', 'e2e-consent-r242-1').second)
        .to eq('TOYBACO_E2E_PURGE_GROWTH prefix=e2e-consent-r242-1 trials=0 identities=0 installations=0')
      expect(run!('e2e_purge_accounts', 'e2e-consent-r242-1'))
        .to eq(purged('e2e-consent-r242-1', 'accounts=0 users=0 skipped_users=0 remaining=0'))
    end

    it '店舗を消した後に、prefix の合成 id の開通の受付(消した店舗に結んだもの・店舗の無い失敗のもの)と event・案内を消して件数を最後の行に出し、E2E 以外と消さない店舗の受付は残す' do
      owner, store = register('r251-1')
      bound = opening_request('cs_test_e2exconsentxr251x1o', 'evt_e2exconsentxr251x1o', account: store, owner: owner)
      Toybaco::OpeningNotice.create!(opening_request_id: bound.id, request_id: 'initial', actor_id: owner.id, retain_until: 10.years.from_now)
      register('r252-1')
      failed = opening_request('cs_test_e2exconsentxr252x1o', 'evt_e2exconsentxr252x1o')
      run_owner, run_store = register('r253-1')
      # 消さない店舗(E2E 以外の店舗)に結んだ受付は、prefix の合成 id でも消さない。E2E 以外の Session の受付にも触れない。
      kept = [opening_request('cs_test_e2exconsentxr253x1o', 'evt_e2exconsentxr253x1o', account: create(:account, name: '残す店舗'), owner: run_owner),
              opening_request('cs_test_customer2511', 'evt_customer2511')]
      expect(run!('e2e_purge_accounts', 'e2e-consent-r251-1'))
        .to eq(purged('e2e-consent-r251-1', 'accounts=1 users=1 skipped_users=0 remaining=0', 'trials=0 identities=0 installations=0',
                      'requests=1 events=1 notices=1'))
      expect(%w[r252-1 r253-1].map { |run| run!('e2e_purge_accounts', "e2e-consent-#{run}").last })
        .to eq(['TOYBACO_E2E_PURGE_OPENING prefix=e2e-consent-r252-1 requests=1 events=1 notices=0',
                'TOYBACO_E2E_PURGE_OPENING prefix=e2e-consent-r253-1 requests=0 events=0 notices=0'])
      expect([Toybaco::OpeningRequest.where(id: [bound.id, failed.id]).count, Toybaco::OpeningNotice.where(opening_request_id: bound.id).count,
              Toybaco::BillingEvent.where(opening_request_id: [bound.id, failed.id]).count]).to eq([0, 0, 0])
      expect([Toybaco::OpeningRequest.where(id: kept.map(&:id)).count, Toybaco::BillingEvent.where(opening_request_id: kept.map(&:id)).count,
              Account.exists?(run_store.id)]).to eq([2, 2, false])
    end

    it '族の prefix(e2e-consent-r)で呼ぶと、前回までの複数の run の店舗の無い開通の受付と event を合成 id の形で消し、Stripe の実 id の形と形の崩れた行は残す' do
      register('r254-1')
      failed = %w[r255x1 r256x1].map { |run| opening_request("cs_test_e2exconsentx#{run}o", "evt_e2exconsentx#{run}o") }
      # 受付に結ぶ前に止まった run の event(opening_request_id が NULL)。
      unbound = Toybaco::BillingEvent.create!(event_id: 'evt_e2exconsentxr257x1o', mode: 'test', action: 'opening_checkout',
                                              reference_id: 'cs_test_e2exconsentxr257x1o', snapshot: { 'id' => 'evt_e2exconsentxr257x1o' },
                                              payload_digest: 'fixture', next_attempt_at: Time.now.utc, deadline_at: 1.day.from_now)
      # Stripe の実 id の形(cs_test_ の後ろが英大文字・小文字・数字の混ざった並びで o で終わらない)と、前方一致はするが厳格な形でない行。
      kept = [opening_request('cs_test_a1B2c3D4e5F6g7H8i9J0kLmNoPqRsTuVwXyZ', 'evt_1QwErTyUiOpAsDfGhJkL'),
              opening_request('cs_test_e2exconsentxr9Xa1o', 'evt_e2exconsentxr9Xa1o')]
      expect(run!('e2e_purge_accounts', 'e2e-consent-r'))
        .to eq(purged('e2e-consent-r', 'accounts=1 users=1 skipped_users=0 remaining=0', 'trials=0 identities=0 installations=0',
                      'requests=2 events=3 notices=0'))
      expect([Toybaco::OpeningRequest.where(id: failed.map(&:id)).count, Toybaco::BillingEvent.where(opening_request_id: failed.map(&:id)).count,
              Toybaco::BillingEvent.exists?(unbound.id)]).to eq([0, 0, false])
      expect([Toybaco::OpeningRequest.where(id: kept.map(&:id)).count, Toybaco::BillingEvent.where(opening_request_id: kept.map(&:id)).count])
        .to eq([2, 2])
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
        .to eq(purged('e2e-consent-r209-1', 'accounts=1 users=1 skipped_users=1 remaining=0'))
      expect([Account.exists?(store.id), User.exists?(owner.id), User.exists?(member.id)]).to eq([false, false, true])
      expect(AccountUser.where(user_id: member.id).pluck(:account_id)).to eq([elsewhere.id])
    end

    it '削除の transaction の中で積まれる job(所属の後始末・destroy_async の削除・イベントの配信)は commit の後にだけ送る' do
      _, store = register('r213-1')
      create(:inbox, account: store)
      queue_adapter.enqueued_jobs.clear
      inside = nil
      allow(described_class::Purge).to receive(:remaining?).and_wrap_original do |original, *arguments|
        inside = queue_adapter.enqueued_jobs.size
        original.call(*arguments)
      end
      expect(run!('e2e_purge_accounts', 'e2e-consent-r213-1').first).to end_with('accounts=1 users=1 skipped_users=0 remaining=0')
      expect(inside).to eq(0)
      expect(Agents::DestroyJob).to have_been_enqueued.once
      expect(EventDispatcherJob).to have_been_enqueued.at_least(:once)
      expect(ActiveRecord::DestroyAssociationAsyncJob).to have_been_enqueued.at_least(:once)
      expect(ActiveJob::Base.enqueue_after_transaction_commit).to eq(:never)
    end

    it '契約者の所属が既に無くても(Platform で所属を消した後など)、確かめた上で契約者も消す(固定メールの利用者を残さない)' do
      owner, store = register('r211-1')
      AccountUser.find_by!(account: store, user: owner).destroy!
      expect(run!('e2e_purge_accounts', 'e2e-consent-r211-1'))
        .to eq(purged('e2e-consent-r211-1', 'accounts=1 users=1 skipped_users=0 remaining=0'))
      expect([Account.exists?(store.id), User.exists?(owner.id)]).to eq([false, false])
    end

    it '選んだ後に店舗の名前が E2E の形から変われば、行ロックして読み直して何も消さずに abort する' do
      owner, store = register('r212-1')
      allow(described_class).to receive(:accounts).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap { Account.find(store.id).update!(name: '本番の店舗') }
      end
      expect(refusal('e2e_purge_accounts', 'e2e-consent-r212-1')).to eq("account=#{store.id} の名前か状態が選んだ後に変わったため削除しません。")
      expect([Account.exists?(store.id), User.exists?(owner.id), AccountUser.where(account_id: store.id).count]).to eq([true, true, 1])
    end

    it '選んだ後に先頭 5 件の外の一致した店舗が prefix の外の名前に変われば、一致した店舗を全て行ロックして読み直し、何も消さずに abort する' do
      owners, stores = (1..6).map { |index| register("r236-#{index}") }.transpose
      # 1 件目の契約者が 6 件目にも所属する(古い一致集合を信じると、残す契約者と判定して先頭 5 件を消してしまう配置)。
      create(:account_user, account: stores.last, user: owners.first, role: :agent)
      allow(described_class).to receive(:accounts).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap { Account.find(stores.last.id).update!(name: '本番の店舗') }
      end
      expect(refusal('e2e_purge_accounts', 'e2e-consent-r236-')).to eq("account=#{stores.last.id} の名前か状態が選んだ後に変わったため削除しません。")
      expect([Account.where(id: stores.map(&:id)).count, User.where(id: owners.map(&:id)).count]).to eq([6, 6])
      expect(AccountUser.where(account_id: stores.map(&:id)).count).to eq(7)
    end

    it '選んだ後に先頭 5 件の外の一致した店舗が prefix に一致するが E2E の店舗名の形でない名前に変わっても、何も消さずに abort する' do
      owners, stores = (1..6).map { |index| register("r237-#{index}") }.transpose
      create(:account_user, account: stores.last, user: owners.first, role: :agent)
      allow(described_class).to receive(:accounts).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap { Account.find(stores.last.id).update!(name: 'e2e-consent-registration') }
      end
      expect(refusal('e2e_purge_accounts', 'e2e-consent-r')).to eq("account=#{stores.last.id} の名前か状態が選んだ後に変わったため削除しません。")
      expect([Account.where(id: stores.map(&:id)).count, User.where(id: owners.map(&:id)).count]).to eq([6, 6])
      expect(AccountUser.where(account_id: stores.map(&:id)).count).to eq(7)
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
        .to eq(purged('e2e-consent-r203-1', 'accounts=1 users=1 skipped_users=0 remaining=0'))
      expect(run!('e2e_purge_accounts', 'e2e-consent-r203-1'))
        .to eq(purged('e2e-consent-r203-1', 'accounts=0 users=0 skipped_users=0 remaining=0'))
      expect(Account.exists?(store.id)).to be(false)
      expect(new_rows.pluck(:action, :result)).to eq([%w[rake.toybaco:e2e_purge_accounts started], %w[rake.toybaco:e2e_purge_accounts ok]] * 2)
    end

    it '一致する店舗が 5 件を超えれば id の順の先頭 5 件だけを消して残りの件数を出し、繰り返せば全て消せる' do
      stores = (1..7).map { |index| create(:account, name: "e2e-consent-r231-#{index}") }
      expect(run!('e2e_purge_accounts', 'e2e-consent-r231-'))
        .to eq(purged('e2e-consent-r231-', 'accounts=5 users=0 skipped_users=0 remaining=2'))
      expect(Account.where(id: stores.map(&:id)).order(:id).pluck(:id)).to eq(stores.last(2).map(&:id))
      expect(run!('e2e_purge_accounts', 'e2e-consent-r231-'))
        .to eq(purged('e2e-consent-r231-', 'accounts=2 users=0 skipped_users=0 remaining=0'))
      expect(Account.where(id: stores.map(&:id)).count).to eq(0)
    end

    it '同じ E2E の契約者が先頭 5 件とその外の一致した店舗の両方に所属すれば、abort せずに契約者を消さずに数えて先頭 5 件を消し、次の呼び出しで消す' do
      owners, stores = (1..5).map { |index| register("r232-#{index}") }.transpose
      shared = owners.first
      # 1 件目の契約者が、6 件目(同じ利用者の 2 つ目の店舗)の契約者でもある。7 件目は別の契約者の店舗。
      sixth = create(:account, name: 'e2e-consent-r232-6', internal_attributes: registration_state(shared.id))
      create(:account_user, account: sixth, user: shared, role: :administrator)
      last_owner, seventh = register('r232-7')
      user_ids = [*owners, last_owner].map(&:id)
      account_ids = [*stores, sixth, seventh].map(&:id)
      expect(run!('e2e_purge_accounts', 'e2e-consent-r232-'))
        .to eq(purged('e2e-consent-r232-', 'accounts=5 users=4 skipped_users=1 remaining=2'))
      expect(Account.where(id: account_ids).order(:id).pluck(:id)).to eq([sixth.id, seventh.id])
      expect(User.where(id: user_ids).order(:id).pluck(:id)).to eq([shared.id, last_owner.id])
      expect(AccountUser.where(user_id: shared.id).pluck(:account_id)).to eq([sixth.id])
      expect(run!('e2e_purge_accounts', 'e2e-consent-r232-'))
        .to eq(purged('e2e-consent-r232-', 'accounts=2 users=2 skipped_users=0 remaining=0'))
      expect([Account.where(id: account_ids).count, User.where(id: user_ids).count]).to eq([0, 0])
      expect(AccountUser.where(account_id: account_ids).or(AccountUser.where(user_id: user_ids)).count).to eq(0)
    end

    it '契約者でない E2E の利用者が先頭 5 件とその外の一致した店舗の両方に所属すれば、消さずに数え、所属が残りの店舗だけになった次の呼び出しで消す' do
      stores = (1..6).map { |index| create(:account, name: "e2e-consent-r233-#{index}") }
      member = create(:user, email: 'qa+e2e-consent-r233-member@example.com', account: stores[1], role: :agent)
      create(:account_user, account: stores.last, user: member, role: :agent)
      expect(run!('e2e_purge_accounts', 'e2e-consent-r233-'))
        .to eq(purged('e2e-consent-r233-', 'accounts=5 users=0 skipped_users=1 remaining=1'))
      expect([User.exists?(member.id), AccountUser.where(user_id: member.id).pluck(:account_id)]).to eq([true, [stores.last.id]])
      expect(run!('e2e_purge_accounts', 'e2e-consent-r233-'))
        .to eq(purged('e2e-consent-r233-', 'accounts=1 users=1 skipped_users=0 remaining=0'))
      expect([Account.where(id: stores.map(&:id)).count, User.exists?(member.id)]).to eq([0, false])
    end

    it '契約者が先頭 5 件の外の一致した店舗に加えて一致した店舗の外(prefix の外の店舗)にも所属すれば、店舗を消す前に abort して何も消さない' do
      owners, stores = (1..6).map { |index| register("r234-#{index}") }.transpose
      shared = owners.first
      create(:account_user, account: stores.last, user: shared, role: :agent)
      create(:account_user, account: create(:account, name: '本番の店舗'), user: shared, role: :agent)
      expect(refusal('e2e_purge_accounts', 'e2e-consent-r234-'))
        .to eq("account=#{stores.first.id} の契約者 user=#{shared.id} が E2E の利用者でないか、ほかの店舗にも所属するため削除しません。")
      expect([Account.where(id: stores.map(&:id)).count, User.where(id: owners.map(&:id)).count]).to eq([6, 6])
      expect(AccountUser.where(user_id: shared.id).count).to eq(3)
    end

    it '一致した店舗のうち先頭 5 件の外の 1 件だけが E2E の店舗名の形でなくても(実店舗の e2e-consent-registration)、1 件も消さずに abort する' do
      owners, stores = (1..5).map { |index| register("r235-#{index}") }.transpose
      real = create(:account, name: 'e2e-consent-registration')
      expect(described_class.accounts('e2e-consent-r').map(&:id)).to eq([*stores, real].map(&:id))
      expect(refusal('e2e_purge_accounts', 'e2e-consent-r'))
        .to eq('prefix=e2e-consent-r に一致する店舗に、E2E の店舗名の形(e2e-consent-r<run>-<attempt>)でない店舗が 1 件あるため削除しません。')
      expect([Account.where(id: [*stores, real].map(&:id)).count, User.where(id: owners.map(&:id)).count]).to eq([6, 5])
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

    it '削除を読み直して店舗が残っていれば abort し、所属と利用者の削除も、その間に積まれた削除の job も取り消す' do
      owner, store = register('r205-1')
      inbox = create(:inbox, account: store)
      create(:inbox_member, user: owner, inbox: inbox)
      team_member = create(:team_member, user: owner, team: create(:team, account: store))
      conversation = create(:conversation, account: store, inbox: inbox, assignee: owner)
      queue_adapter.enqueued_jobs.clear
      allow(Account).to receive(:exists?).and_call_original
      allow(Account).to receive(:exists?).with(id: [store.id]).and_return(true)
      # 会話の関連を消すときに初めて読む model の非推奨警告が abort の文に混ざらないよう、警告を止めて実行する。
      expect(Rails.application.deprecators.silence { refusal('e2e_purge_accounts', 'e2e-consent-r205-1') })
        .to eq('prefix=e2e-consent-r205-1 の削除を読み直すと店舗・利用者・所属・bot・体験と自動応答の記録が残っているため、削除を取り消します。')
      # 所属の削除の Agents::DestroyJob・destroy_async の削除・イベントの配信は commit の後にだけ送るため、rollback では残らない。
      # 残るのは、削除の前に Postiz で外した所属を戻す PostizMembershipJob(overlay の after_rollback が積む、戻すための job)だけ。
      expect(queue_adapter.enqueued_jobs.map { |job| [job[:job], job['arguments']] }).to eq([[Toybaco::PostizMembershipJob, [owner.id, store.id]]])
      perform_enqueued_jobs
      expect([Account.where(id: store.id).count, User.where(id: owner.id).count, AccountUser.where(account_id: store.id).count]).to eq([1, 1, 1])
      expect([owner.notification_settings.where(account_id: store.id).count, InboxMember.where(user_id: owner.id, inbox_id: inbox.id).count,
              TeamMember.exists?(team_member.id), conversation.reload.assignee_id]).to eq([1, 1, true, owner.id])
      expect(new_rows.pluck(:result)).to eq(%w[started failed])
    end
  end
end
