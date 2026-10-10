# frozen_string_literal: true

require 'rails_helper'
require 'active_support/testing/stream'

Rails.application.load_tasks unless Rake::Task.task_defined?('toybaco:e2e_trial')

# staging の E2E の Stripe を使わない 2 経路(体験の開始・おまかせ自動返信の開始)の運営 rake(toybaco:e2e_trial / e2e_managed_auto)。
# 無料登録の E2E で有効にした店舗に、本番の開始処理(TrialStart#start!・ManagedAutoInstall の create! → change!)で同意の記録を残すこと、
# その前提(店舗情報・IMAP の受信箱と bot・回答例・Standard・bot を外すこと)を rake が外部に接続せずに作ること(IMAP は Net::IMAP.new を
# 置き換えて接続の試みを数え、0 回であることを確かめる)、staging 以外と prefix の形と対象の店舗の検査、断られたときの理由のキーと
# 取り消し、2 回目の skipped、機能フラグが off の skipped を確かめる。おまかせ自動返信の設置は外側の transaction の中を拒むため
# (ManagedAuto.locked)、設置まで進む例は transactional fixtures を使わずに実行し、作った行を後で消す。無料登録 → 確認 → 体験 →
# おまかせ自動返信 → 同意の記録の確認 → 後片付けを続けて実行し、規約同意の記録が 3 経路になることも確かめる。
# Postiz の DB は外部の境界として PostizSync をスタブする(ops_e2e_consent_spec と同じ)。
# 置き場所は他の overlay spec(spec/lib/toybaco/*_spec.rb)と揃え、rspec manifest の名簿で固定している。
RSpec.describe Toybaco::Ops::E2eGrowth do # rubocop:disable RSpec/SpecFilePathFormat
  include ActiveSupport::Testing::Stream
  include ActiveJob::TestHelper

  let!(:baseline) { Toybaco::OperatorAction.maximum(:id).to_i }
  let(:staging_only) { 'は staging 専用です。production と環境が不明なときは実行しません。' }
  let(:prefix_error) { 'prefix は e2e-consent- に続けて英小文字・数字・- を 1〜40 字で指定してください。' }
  let(:draft) { "#{Toybaco::Growth::ReplyResult::DRAFT_PREFIX}10時から18時まで営業しています。" }

  around do |example|
    with_modified_env(TOYBACO_DEPLOYMENT_ENVIRONMENT: 'staging', TOYBACO_OPS_ACTOR: nil, TOYBACO_OPS_SOURCE: nil,
                      TOYBACO_MANAGED_AUTO_ENABLED: 'true') { example.run }
  end

  before do
    allow(Toybaco::PostizSync).to receive(:sync!).and_return(organization_id: 'postiz-org', user_id: 'postiz-user', role: 'ADMIN')
    allow(Toybaco::PostizSync).to receive(:revoke_membership!).and_return(:revoked)
    allow(Toybaco::PostizSync).to receive(:disable_account!).and_return(:disabled)
    allow(Toybaco::PostizSync).to receive(:disable_user!).and_return(:disabled)
    # E2E の受信箱のホストは名前解決されない。接続を試みれば到達しない時の例外にし(ImapVerification はログインの失敗として扱う)、回数を数える。
    allow(Net::IMAP).to receive(:new).and_raise(SocketError, 'E2E の受信箱には接続しない')
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

  # 成功するはずの呼び出し。想定外の abort(SystemExit)は RSpec の実行全体を止めるため、abort の文を添えてこの例の失敗に置き換える。
  def run!(name, *values)
    capture(:stdout) { run_task(name, *values) }.lines(chomp: true)
  rescue SystemExit => e
    raise RSpec::Expectations::ExpectationNotMetError, "toybaco:#{name}[#{values.join(',')}] が abort しました: #{e.message}"
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
    Toybaco::Growth::FreeRegistration.new.register!(account_name: "e2e-consent-#{run}", user_full_name: "体験 確認 #{run}",
                                                    email: email, password: 'Passw0rd!x2Y')
  end

  # 無料登録の E2E で確認と有効化まで済んだ店舗(e2e_confirm_user と同じ User#confirm と FreeRegistration#activate!)。
  def active_store(run)
    user, account = register(run)
    user.confirm
    Toybaco::Growth::FreeRegistration.new.activate!(user, account)
    [user.reload, account.reload]
  end

  def routes(account)
    Toybaco::LegalTerms.records(account.reload).pluck('route')
  end

  def trial_line(account, result, reason)
    "TOYBACO_E2E_TRIAL result=#{result} account=#{account&.id || '-'} reason=#{reason}"
  end

  def auto_line(account, result, reason)
    "TOYBACO_E2E_MANAGED_AUTO result=#{result} account=#{account&.id || '-'} reason=#{reason}"
  end

  # 体験の前提として rake が作る行の数(店舗情報・受信箱・bot・会話・メッセージ・体験・同意の記録)。
  def footprint(account)
    account.reload
    [Toybaco::Growth::StoreFacts.new(account).read['confirmed'], Channel::Email.where(account_id: account.id).count, account.inboxes.count,
     AgentBot.where(account_id: account.id).count, Conversation.where(account_id: account.id).count, Message.where(account_id: account.id).count,
     Toybaco::GrowthTrial.where(account_id: account.id).count, routes(account)]
  end

  shared_examples 'staging 以外と prefix の検査' do |task|
    it 'production と環境が不明なときは引数を読む前に abort し、prefix が e2e-consent- の形でないか余分な引数があれば入力を出さずに abort する' do
      _, account = active_store('r390-1')
      [{ TOYBACO_DEPLOYMENT_ENVIRONMENT: 'production' }, { TOYBACO_DEPLOYMENT_ENVIRONMENT: nil },
       { TOYBACO_DEPLOYMENT_ENVIRONMENT: 'Staging' }].each do |env|
        with_modified_env(env) do
          expect(refusal(task, 'e2e-consent-r390-1')).to eq("#{task} #{staging_only}")
          expect(refusal(task, '%')).to eq("#{task} #{staging_only}")
        end
      end
      [nil, '', 'e2e-consent-', 'E2E-consent-r390-1', 'e2e-consent-r390_1', ' e2e-consent-r390-1', :'e2e-consent-r390-1']
        .each { |value| expect(refusal(task, value)).to eq(prefix_error) }
      expect(refusal(task, 'e2e-consent-r390-1', 'x')).to eq('引数は prefix の 1 つだけを指定してください。')
      expect(footprint(account)).to eq([false, 0, 0, 0, 0, 0, 0, ['free_registration']])
      expect(new_rows.pluck(:result)).to eq(%w[started failed] * 14)
    end
  end

  describe 'toybaco:e2e_trial' do
    it 'staging で体験の前提を作って TrialStart#start! で開始し、IMAP の identity と route trial の同意を契約者で記録する(IMAP に接続しない)' do
      user, account = active_store('r301-1')
      lines = run!('e2e_trial', 'e2e-consent-r301-1')
      expect(lines).to eq([trial_line(account, 'started', '-')])
      trial = Toybaco::GrowthTrial.find_by!(account_id: account.id)
      identity = Toybaco::Growth::TrialConnection.digest('imap', 'imap.e2e-imap.invalid/e2e-consent-r301-1@e2e-imap.invalid')
      expect(trial.identities.map { |row| row.slice(:provider, :identity_digest).symbolize_keys }).to eq([identity])
      expect(Toybaco::LegalTerms.records(account.reload).map { |record| record.values_at('route', 'user_id') })
        .to eq([['free_registration', user.id], ['trial', user.id]])
      example = Message.find(trial.example_id)
      expect([example.private, example.content, example.sender_type, example.inbox.channel.imap_address, example.inbox.channel.smtp_enabled])
        .to eq([true, draft, 'AgentBot', 'imap.e2e-imap.invalid', false])
      expect(Toybaco::Growth::TrialExample.new(account).find(example.id, revision: trial.facts_revision)).to eq(example)
      expect(Net::IMAP).not_to have_received(:new)
      expect(lines.join("\n")).not_to include('@', user.name, Toybaco::Ops::E2eGrowth::TrialSeam::PASSWORD)
    end

    it '開始の後は、体験の枠・全自動の返信・回答例の操作の記録が本番の開始と同じ形になり、監査行は started と ok' do
      _, account = active_store('r307-1')
      run!('e2e_trial', 'e2e-consent-r307-1')
      trial = Toybaco::GrowthTrial.find_by!(account_id: account.id)
      grant = Toybaco::GrowthAiGrant.find_by!(account_id: account.id, source: 'trial')
      expect([grant.units, grant.source_key, grant.ends_at]).to eq([100, "trial:#{trial.id}", trial.ends_at])
      expect(Toybaco::AiReplyMode.read_from(account.reload)).to eq('auto')
      operation = Toybaco::GrowthAiOperation.find_by!(account_id: account.id, kind: 'reply_draft')
      expect([operation.state, operation.result_reference]).to eq(['consumed', "message:#{trial.example_id}"])
      digest = Toybaco::Ops::Audit.params_digest({ 'prefix' => 'e2e-consent-r307-1' })
      expect(new_rows.pluck(:action, :result, :params_digest))
        .to eq([['rake.toybaco:e2e_trial', 'started', digest], ['rake.toybaco:e2e_trial', 'ok', digest]])
    end

    it '2 回目は何も書かずに skipped(already_done)で正常に終わり、記録を増やさない' do
      _, account = active_store('r302-1')
      run!('e2e_trial', 'e2e-consent-r302-1')
      before = footprint(account)
      expect(run!('e2e_trial', 'e2e-consent-r302-1')).to eq([trial_line(account, 'skipped', 'already_done')])
      expect(footprint(account)).to eq(before)
      expect(before).to eq([true, 1, 1, 1, 1, 2, 1, %w[free_registration trial]])
      expect(new_rows.pluck(:result)).to eq(%w[started ok started ok])
    end

    it_behaves_like 'staging 以外と prefix の検査', 'e2e_trial'

    it '対象の店舗が 0 件・2 件・E2E の店舗名の形でない・停止中・契約者がメール確認前なら、理由を 1 行で出して abort し、何も作らない' do
      expect(refusal('e2e_trial', 'e2e-consent-r303-')).to eq(trial_line(nil, 'refused', 'no_account'))
      first = active_store('r303-1').last
      active_store('r303-2')
      expect(refusal('e2e_trial', 'e2e-consent-r303-')).to eq(trial_line(nil, 'refused', 'multiple_accounts'))
      create(:account, name: 'e2e-consent-r304-1-old')
      expect(refusal('e2e_trial', 'e2e-consent-r304-')).to eq(trial_line(nil, 'refused', 'name_format'))
      pending = register('r305-1').last
      expect(refusal('e2e_trial', 'e2e-consent-r305-1')).to eq(trial_line(pending, 'refused', 'account_inactive'))
      owner, unconfirmed = active_store('r306-1')
      owner.update_columns(confirmed_at: nil) # rubocop:disable Rails/SkipsModelValidations
      expect(refusal('e2e_trial', 'e2e-consent-r306-1')).to eq(trial_line(unconfirmed, 'refused', 'owner_unconfirmed'))
      expect([first, pending, unconfirmed].map { |account| footprint(account).drop(1).take(6) }.uniq).to eq([[0, 0, 0, 0, 0, 0]])
    end

    it '前回の run の identity が別の店舗の体験に残っていれば、TrialStart が used_elsewhere で断り、そのキーを出して前提も残さない(1 つの transaction)' do
      _, account = active_store('r308-1')
      other = Toybaco::GrowthTrial.create!(account_id: create(:account).id, facts_revision: 'old', example_id: 1,
                                           starts_at: 1.day.ago, ends_at: 13.days.from_now)
      other.identities.create!(Toybaco::Growth::TrialConnection.digest('imap', 'imap.e2e-imap.invalid/e2e-consent-r308-1@e2e-imap.invalid'))
      queue_adapter.enqueued_jobs.clear
      expect(refusal('e2e_trial', 'e2e-consent-r308-1')).to eq(trial_line(account, 'refused', 'used_elsewhere'))
      expect(footprint(account)).to eq([false, 0, 0, 0, 0, 0, 0, ['free_registration']])
      expect(Toybaco::GrowthAiOperation.where(account_id: account.id).count).to eq(0)
      # 前提を作る間に積まれる job(イベントの配信など)は commit の後にだけ送るため、取り消した後には残らない。
      expect(queue_adapter.enqueued_jobs).to eq([])
      expect(Net::IMAP).not_to have_received(:new)
    end

    it 'ほかの IMAP の受信箱が既にある店舗では(TrialStart が全ての受信箱にログインしうる)、前提を作らずに other_mail_inbox で断り、接続しない' do
      _, account = active_store('r314-1')
      channel = Channel::Email.create!(account: account, email: 'shop-r314@example.test', imap_enabled: true, imap_login: 'shop-r314@example.test',
                                       imap_password: 'fixture', imap_address: 'imap.example.test', imap_port: 993)
      account.inboxes.create!(channel: channel, name: '既存のメール')
      expect(refusal('e2e_trial', 'e2e-consent-r314-1')).to eq(trial_line(account, 'refused', 'other_mail_inbox'))
      expect(footprint(account)).to eq([false, 1, 1, 0, 0, 0, 0, ['free_registration']])
      expect(Net::IMAP).not_to have_received(:new)
    end

    it '店舗情報が確認済みにならなければ(保存が効かない)、回答例の受け口が facts_required で断り、その理由を出して前提も残さない' do
      _, account = active_store('r309-1')
      allow(Toybaco::Growth::StoreFacts).to receive(:new).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap { |facts| allow(facts).to receive(:save!) }
      end
      expect(refusal('e2e_trial', 'e2e-consent-r309-1')).to eq(trial_line(account, 'refused', 'example_facts_required'))
      expect(footprint(account)).to eq([false, 0, 0, 0, 0, 0, 0, ['free_registration']])
    end

    it '体験の対象でないプラン(自動応答が契約に含まれる Standard)なら、TrialStart が included で断り、そのキーを出す' do
      _, account = active_store('r310-1')
      terms = Toybaco::PlanCatalog.default.definition('standard', '2026-09-25.1')
      Toybaco::Entitlements.apply!(account, Toybaco::Entitlements.snapshot_for(terms, cycle: 'month'))
      expect(refusal('e2e_trial', 'e2e-consent-r310-1')).to eq(trial_line(account, 'refused', 'included'))
      expect(footprint(account).drop(1)).to eq([0, 0, 0, 0, 0, 0, ['free_registration']])
      expect(new_rows.pluck(:result)).to eq(%w[started failed])
    end
  end

  describe 'toybaco:e2e_managed_auto' do
    it_behaves_like 'staging 以外と prefix の検査', 'e2e_managed_auto'

    it '機能フラグが true でなければ、何も書かずに skipped(flag_off)の 1 行で abort する' do
      _, account = active_store('r311-1')
      run!('e2e_trial', 'e2e-consent-r311-1')
      bots = lambda do
        [account.reload.internal_attributes, AgentBot.where(account_id: account.id).pluck(:id), AgentBotInbox.where(account_id: account.id).count]
      end
      saved = bots.call
      [nil, 'false', 'TRUE'].each do |value|
        with_modified_env(TOYBACO_MANAGED_AUTO_ENABLED: value) do
          expect(refusal('e2e_managed_auto', 'e2e-consent-r311-1')).to eq(auto_line(account, 'skipped', 'flag_off'))
        end
      end
      expect(bots.call).to eq(saved)
      expect(Toybaco::GrowthAutoInstallation.where(account_id: account.id).count).to eq(0)
    end

    it '体験の前(trial_missing)・体験の bot のほかに bot がある(other_bots)・対象の店舗が無いときは、理由を出して契約も bot も変えない' do
      expect(refusal('e2e_managed_auto', 'e2e-consent-r312-')).to eq(auto_line(nil, 'refused', 'no_account'))
      _, account = active_store('r312-1')
      expect(refusal('e2e_managed_auto', 'e2e-consent-r312-1')).to eq(auto_line(account, 'refused', 'trial_missing'))
      run!('e2e_trial', 'e2e-consent-r312-1')
      create(:agent_bot, account: account)
      expect(refusal('e2e_managed_auto', 'e2e-consent-r312-1')).to eq(auto_line(account, 'refused', 'other_bots'))
      expect(Toybaco::Entitlements.contract_for(account.reload)['plan_id']).to eq('free')
      expect([AgentBot.where(account_id: account.id).count, AgentBotInbox.where(account_id: account.id).count]).to eq([2, 1])
      expect(routes(account)).to eq(%w[free_registration trial])
    end

    it '外側の transaction の中から呼ぶと(ManagedAuto.locked が拒む)設置せずに install_invalid の 1 行で abort する' do
      _, account = active_store('r313-1')
      run!('e2e_trial', 'e2e-consent-r313-1')
      # transactional fixtures の transaction が外側にある。設置と全自動への切り替えは、その中では進まない。
      expect(ActiveRecord::Base.connection.transaction_open?).to be(true)
      expect(refusal('e2e_managed_auto', 'e2e-consent-r313-1')).to eq(auto_line(account, 'refused', 'install_invalid'))
      expect(Toybaco::GrowthAutoInstallation.where(account_id: account.id).count).to eq(0)
      expect(routes(account)).to eq(%w[free_registration trial])
    end

    it '既存の設置がこの seam の未完了の設置でなければ(契約者以外の設置・同意の記録の無い全自動)、再開せずに installation_not_auto で断る' do
      user, account = active_store('r315-1')
      run!('e2e_trial', 'e2e-consent-r315-1')
      inbox = Channel::Email.find_by!(account_id: account.id).inbox
      installation = Toybaco::GrowthAutoInstallation.create!(account_id: account.id, inbox_id: inbox.id, bot_id: 900_000 + account.id,
                                                             actor_id: create(:user).id, request_id: SecureRandom.uuid, epoch: SecureRandom.uuid)
      expect(refusal('e2e_managed_auto', 'e2e-consent-r315-1')).to eq(auto_line(account, 'refused', 'installation_not_auto'))
      installation.update!(actor_id: user.id, state: 'auto')
      expect(refusal('e2e_managed_auto', 'e2e-consent-r315-1')).to eq(auto_line(account, 'refused', 'installation_not_auto'))
      expect(Toybaco::Entitlements.contract_for(account.reload)['plan_id']).to eq('free')
      expect([AgentBot.where(account_id: account.id).count, routes(account)]).to eq([1, %w[free_registration trial]])
    end

    describe '外側の transaction を持たない実行(rake と同じ)' do
      self.use_transactional_tests = false

      # transactional fixtures を使わないので、例の前の各表の id の最大値を控え、例の後にそれより後の行を全ての表から消す(この例のほかに
      # 書き込む接続は無い。後片付けの rake が途中で止まった例や、destroy_async の job が test adapter で走らずに残る行も消す)。外部キーの
      # 検査を止めた別の DB セッションで消す。
      let!(:id_floors) { id_floors_now }

      after { delete_rows_after(id_floors) }

      def id_floors_now
        connection = ActiveRecord::Base.connection
        connection.tables.select { |table| connection.columns(table).any? { |column| column.name == 'id' && column.type == :integer } }
                  .index_with { |table| connection.select_value("SELECT COALESCE(MAX(id), 0) FROM #{connection.quote_table_name(table)}").to_i }
      end

      def delete_rows_after(floors)
        connection = ActiveRecord::Base.connection_db_config.new_connection
        connection.execute('SET session_replication_role = replica')
        floors.each { |table, floor| connection.execute("DELETE FROM #{connection.quote_table_name(table)} WHERE id > #{Integer(floor)}") }
      ensure
        connection&.disconnect!
      end

      it '体験の後の店舗を Standard にして体験の bot を外し、外側の transaction なしで設置と全自動への切り替えを契約者で行い、route managed_auto を記録する' do
        user, account = active_store('r321-1')
        run!('e2e_trial', 'e2e-consent-r321-1')
        opened = []
        allow(Toybaco::Growth::ManagedAutoInstall).to receive(:new).and_wrap_original do |original, *arguments, **options|
          opened << ActiveRecord::Base.connection.transaction_open?
          original.call(*arguments, **options)
        end
        expect(run!('e2e_managed_auto', 'e2e-consent-r321-1')).to eq([auto_line(account, 'installed', '-')])
        installation = Toybaco::GrowthAutoInstallation.find_by!(account_id: account.id)
        # 設置(create!)と切り替え(change!)の 2 回とも、外側の transaction の無いところで呼ぶ。
        expect([installation.state, installation.actor_id, installation.generation, opened]).to eq(['auto', user.id, 2, [false, false]])
        expect(AgentBot.where(account_id: account.id).pluck(:id, :outgoing_url)).to eq([[installation.bot_id, nil]])
        expect(Toybaco::Entitlements.contract_for(account.reload).values_at('plan_id', 'plan_version', 'cycle'))
          .to eq(%w[standard 2026-09-25.1 month])
        expect(Toybaco::LegalTerms.records(account).map { |record| record.values_at('route', 'user_id') })
          .to eq([['free_registration', user.id], ['trial', user.id], ['managed_auto', user.id]])
        expect(run!('e2e_managed_auto', 'e2e-consent-r321-1')).to eq([auto_line(account, 'skipped', 'already_done')])
      end

      it '設置(create!)の確定後に切り替え(change!)が競合で止まれば install_busy で abort し、再実行は create! を飛ばして切り替えだけを行う' do
        user, account = active_store('r322-1')
        run!('e2e_trial', 'e2e-consent-r322-1')
        calls = Hash.new(0)
        allow(Toybaco::Growth::ManagedAutoInstall).to receive(:new).and_wrap_original do |original, *arguments, **options|
          original.call(*arguments, **options).tap do |service|
            allow(service).to receive(:create!).and_wrap_original do |create, **values|
              calls[:create] += 1
              create.call(**values)
            end
            allow(service).to receive(:change!).and_wrap_original do |change, **values|
              calls[:change] += 1
              raise Toybaco::Growth::InboxRetention::Busy if calls[:change] == 1

              change.call(**values)
            end
          end
        end
        expect(refusal('e2e_managed_auto', 'e2e-consent-r322-1')).to eq(auto_line(account, 'refused', 'install_busy'))
        draft = Toybaco::GrowthAutoInstallation.find_by!(account_id: account.id)
        expect([draft.state, draft.actor_id, draft.generation, routes(account)]).to eq(['draft', user.id, 1, %w[free_registration trial]])
        expect(run!('e2e_managed_auto', 'e2e-consent-r322-1')).to eq([auto_line(account, 'installed', '-')])
        expect([calls, draft.reload.state, draft.generation]).to eq([{ create: 1, change: 2 }, 'auto', 2])
        expect([routes(account), Toybaco::GrowthAutoInstallation.where(account_id: account.id).count])
          .to eq([%w[free_registration trial managed_auto], 1])
        expect(run!('e2e_managed_auto', 'e2e-consent-r322-1')).to eq([auto_line(account, 'skipped', 'already_done')])
      end

      it '無料登録 → 確認 → 体験 → おまかせ自動返信の後、legal_consents_by_name が 3 経路を出し、後片付けで体験と自動応答の記録も消える' do
        user, account = register('r331-1')
        prefix = 'e2e-consent-r331-1'
        %w[e2e_confirm_user e2e_trial e2e_managed_auto].each { |task| run!(task, prefix) }
        expect(run!('legal_consents_by_name', prefix).last(2))
          .to eq(["TOYBACO_LEGAL_CONSENTS account=#{account.id} count=3 routes=free-registration:1,managed-auto:1,trial:1",
                  "TOYBACO_LEGAL_CONSENTS_BY_NAME prefix=#{prefix} accounts=1"])
        trial_ids = Toybaco::GrowthTrial.where(account_id: account.id).pluck(:id)
        expect(run!('e2e_purge_accounts', prefix))
          .to eq(["TOYBACO_E2E_PURGE prefix=#{prefix} accounts=1 users=1 skipped_users=0 remaining=0",
                  "TOYBACO_E2E_PURGE_GROWTH prefix=#{prefix} trials=1 identities=1 installations=1"])
        expect([Account.exists?(account.id), User.exists?(user.id), Toybaco::GrowthTrialIdentity.where(trial_id: trial_ids).count])
          .to eq([false, false, 0])
        expect([Toybaco::GrowthTrial, Toybaco::GrowthAutoInstallation, Toybaco::GrowthAutoCommand, Toybaco::GrowthAutoRequest]
          .map { |model| model.where(account_id: account.id).count }).to eq([0, 0, 0, 0])
        expect(Net::IMAP).not_to have_received(:new)
      end
    end
  end
end
