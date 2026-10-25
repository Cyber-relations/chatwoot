# frozen_string_literal: true

require 'rails_helper'
require 'active_support/testing/stream'

Rails.application.load_tasks unless Rake::Task.task_defined?('toybaco:e2e_visual_store')

# staging の目視用の店舗の運営 rake(toybaco:e2e_visual_store / e2e_visual_purge)。staging 以外では引数を読む前に abort すること、引数の形
# (e2e-visual- の店舗名・1 以上の整数の source_account_id・余分な引数)、作る店舗の初期状態(無料登録で確認と有効化まで済んだ店舗と同じ
# 契約・段階・返信の形・案内の状態で、規約同意の記録は残さない)と、source の店舗の確認済み administrator だけを所属させること、同じ名前の
# 2 回目の skipped、source の検査の理由のキー、削除の範囲(名前が完全に一致する店舗と所属だけを消し、複製した実在の利用者は消さない)、
# E2E の後片付け(e2e_purge_accounts)との分離を確かめる。出力にメールアドレス・氏名を出さないことも確かめる。
# Postiz の DB は外部の境界として PostizSync をスタブする(ops_e2e_consent_spec と同じ)。
# 置き場所は他の overlay spec(spec/lib/toybaco/*_spec.rb)と揃え、rspec manifest の名簿で固定している。
RSpec.describe Toybaco::Ops::E2eVisual do # rubocop:disable RSpec/SpecFilePathFormat
  include ActiveSupport::Testing::Stream
  include ActiveJob::TestHelper

  let!(:baseline) { Toybaco::OperatorAction.maximum(:id).to_i }
  let(:staging_only) { 'は staging 専用です。production と環境が不明なときは実行しません。' }
  let(:name_error) { 'name は e2e-visual- に続けて英小文字・数字・- を 1〜40 字で指定してください。' }
  let(:source_error) { 'source_account_id は 1 以上の整数で指定してください。' }

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

  # 成功するはずの呼び出し。想定外の abort(SystemExit)は RSpec の実行全体を止めるため、abort の文を添えてこの例の失敗に置き換える。
  def run!(name, *values)
    capture(:stdout) { run_task(name, *values) }.lines(chomp: true)
  rescue SystemExit => e
    raise RSpec::Expectations::ExpectationNotMetError, "toybaco:#{name}[#{values.join(',')}] が abort しました: #{e.message}"
  end

  # abort することを確かめ、abort の文(標準エラー)を返す。標準出力には何も出さず、終了コードは 0 でない。
  def refusal(name, *values)
    message = nil
    printed = capture(:stdout) do
      message = capture(:stderr) do
        expect { run_task(name, *values) }.to raise_error(SystemExit) { |error| expect(error.success?).to be(false) }
      end
    end
    expect(printed).to eq('')
    message.chomp
  end

  # 目視の source の店舗。確認済みの administrator 2 人(所属の順を id の順と逆にする)と、未確認の administrator・SuperAdmin の
  # administrator・確認済みの agent を 1 人ずつ所属させる。氏名は出力に出ないことを確かめるため店舗名と変える。
  def source_store
    source = create(:account, name: '目視の元の店舗')
    administrators = Array.new(2) { |index| create(:user, name: "目視 管理者 #{index}") }
    administrators.reverse_each { |user| create(:account_user, account: source, user: user, role: :administrator) }
    unconfirmed = create(:user, name: '目視 未確認', skip_confirmation: false, account: source, role: :administrator)
    admin = create(:super_admin, name: '目視 運営')
    create(:account_user, account: source, user: admin, role: :administrator)
    agent = create(:user, name: '目視 担当者', account: source, role: :agent)
    { source: source, administrators: administrators, others: [unconfirmed, admin, agent] }
  end

  def created(name, fixture)
    run!('e2e_visual_store', name, fixture[:source].id.to_s)
    Account.find_by!(name: name)
  end

  def visual_line(account, result, reason)
    "TOYBACO_E2E_VISUAL result=#{result} account=#{account&.id || '-'} reason=#{reason}"
  end

  describe 'toybaco:e2e_visual_store' do
    it 'staging で、source の店舗の確認済み administrator だけを administrator で所属させた店舗を作り、id と件数だけを出す' do
      fixture = source_store
      source = fixture[:source]
      first, second = fixture[:administrators]
      lines = run!('e2e_visual_store', 'e2e-visual-tour-1', source.id.to_s)
      account = Account.find_by!(name: 'e2e-visual-tour-1')
      expect(lines).to eq(["TOYBACO_E2E_VISUAL result=created account=#{account.id} source=#{source.id} administrators=2 reason=-"])
      # 未確認の administrator・SuperAdmin・agent は所属させない。source の所属は変えない。
      expect(account.account_users.order(:user_id).pluck(:user_id, :role)).to eq([[first.id, 'administrator'], [second.id, 'administrator']])
      expect(AccountUser.where(account_id: source.id).count).to eq(5)
      expect(lines.join("\n")).not_to include('@', *[first, second, *fixture[:others]].map(&:name))
      digest = Toybaco::Ops::Audit.params_digest({ 'name' => 'e2e-visual-tour-1', 'source_account_id' => source.id.to_s })
      expect(new_rows.pluck(:action, :result, :params_digest))
        .to eq([['rake.toybaco:e2e_visual_store', 'started', digest], ['rake.toybaco:e2e_visual_store', 'ok', digest]])
    end

    it '作った店舗は無料登録の有効化の後と同じ契約・段階・返信の形・案内の状態で、規約同意の記録は残さず、利用者のツアーの状態にも触れない' do
      fixture = source_store
      first, second = fixture[:administrators]
      guides = [first, second].map { |user| user.reload.custom_attributes }
      account = created('e2e-visual-tour-2', fixture)
      attrs = account.internal_attributes
      version = Toybaco::PlanCatalog.default.data['free_registration_version']
      expect(Toybaco::Entitlements.contract_for(account).values_at('plan_id', 'plan_version', 'cycle')).to eq(['free', version, nil])
      # 契約者は複製した administrator のうち id が最小の利用者。同意の版・日時(legal_terms_version など)は段階の記録に書かない。
      expect(attrs['toybaco_growth_registration'].except('registered_at', 'free_anchor', 'activated_at'))
        .to eq('phase' => 'active', 'version' => version, 'owner_id' => first.id)
      expect([attrs['toybaco_billing_owner_user_id'], Toybaco::AiReplyMode.read_from(account), account.status, account.locale,
              account.custom_attributes.fetch('onboarding_step', 'missing')]).to eq([first.id, Toybaco::AiReplyMode::DRAFT, 'active', 'ja', nil])
      # 規約同意の記録が無くても、案内(growth guide)は無料登録の店舗と同じく開ける。無料プランの AI の枠は有効化と同じく付く。
      expect([Toybaco::LegalTerms.records(account), Toybaco::Growth::Onboarding.available?(account)]).to eq([[], true])
      expect(Toybaco::GrowthAiGrant.where(account_id: account.id, source: 'included').count).to eq(1)
      expect([first, second].map { |user| user.reload.custom_attributes }).to eq(guides)
    end

    it '同じ名前の 2 回目は何も書かずに skipped(already_exists)で正常に終わり、同じ名前の店舗が 2 件あれば作らずに abort する' do
      fixture = source_store
      account = created('e2e-visual-tour-3', fixture)
      footprint = -> { [Account.count, AccountUser.count, account.reload.internal_attributes] }
      saved = footprint.call
      expect(run!('e2e_visual_store', 'e2e-visual-tour-3', fixture[:source].id.to_s))
        .to eq([visual_line(account, 'skipped', 'already_exists')])
      expect(footprint.call).to eq(saved)
      create(:account, name: 'e2e-visual-tour-3')
      expect(refusal('e2e_visual_store', 'e2e-visual-tour-3', fixture[:source].id.to_s)).to eq(visual_line(nil, 'refused', 'multiple_accounts'))
      expect(Account.where(name: 'e2e-visual-tour-3').count).to eq(2)
      expect(new_rows.pluck(:result)).to eq(%w[started ok started ok started failed])
    end

    it 'source が無い・停止中・名前が e2e- で始まる・確認済みの administrator がいないときは、理由を 1 行で出して abort し(非 0)、店舗を作らない' do
      fixture = source_store
      source = fixture[:source]
      unconfirmed, admin, agent = fixture[:others]
      missing = (Account.maximum(:id).to_i + 1000).to_s
      expect(refusal('e2e_visual_store', 'e2e-visual-r1', missing)).to eq(visual_line(nil, 'refused', 'source_missing'))
      e2e_store = create(:account, name: 'e2e-consent-r501-1')
      create(:account_user, account: e2e_store, user: fixture[:administrators].first, role: :administrator)
      bare = create(:account, name: '確認済みの管理者のいない店舗')
      [[unconfirmed, :administrator], [admin, :administrator], [agent, :agent]].each do |user, role|
        create(:account_user, account: bare, user: user, role: role)
      end
      source.update!(status: :suspended)
      [[source, 'source_inactive'], [e2e_store, 'source_is_e2e'], [bare, 'source_no_administrator']].each do |store, reason|
        expect(refusal('e2e_visual_store', 'e2e-visual-r1', store.id.to_s)).to eq(visual_line(store, 'refused', reason))
      end
      expect(Account.where(name: 'e2e-visual-r1').count).to eq(0)
      expect(new_rows.pluck(:result)).to eq(%w[started failed] * 4)
    end

    it 'production と環境が不明なときは、引数を読む前に abort して店舗を作らず、消さない' do
      fixture = source_store
      account = created('e2e-visual-r2', fixture)
      [{ TOYBACO_DEPLOYMENT_ENVIRONMENT: 'production' }, { TOYBACO_DEPLOYMENT_ENVIRONMENT: nil },
       { TOYBACO_DEPLOYMENT_ENVIRONMENT: 'Staging' }].each do |env|
        with_modified_env(env) do
          expect(refusal('e2e_visual_store', 'e2e-visual-r3', fixture[:source].id.to_s)).to eq("e2e_visual_store #{staging_only}")
          expect(refusal('e2e_visual_store', '%')).to eq("e2e_visual_store #{staging_only}")
          expect(refusal('e2e_visual_purge', 'e2e-visual-r2')).to eq("e2e_visual_purge #{staging_only}")
          expect(refusal('e2e_visual_purge', '%')).to eq("e2e_visual_purge #{staging_only}")
        end
      end
      expect([Account.exists?(account.id), Account.exists?(name: 'e2e-visual-r3')]).to eq([true, false])
      expect(new_rows.pluck(:result)).to eq(%w[started ok] + (%w[started failed] * 12))
    end

    it '引数の形(name が e2e-visual- の形でない・source_account_id が 1 以上の整数でない・余分な引数)が違えば、入力を出さずに abort し、何も作らない' do
      id = source_store[:source].id.to_s
      names = [nil, '', 'e2e-visual-', 'e2e-visual', 'E2E-visual-a', 'e2e-visual-A', 'e2e-visual-a_b', 'e2e-visual-a%', "e2e-visual-#{'a' * 41}",
               ' e2e-visual-a', "e2e-visual-a\n", 'x-e2e-visual-a', 'e2e-consent-r1-1', 'shop', :'e2e-visual-a']
      ids = [nil, '', '0', '012', '-1', '1.5', 'abc', "#{id}\n", " #{id}", '12345678901', 1, :'1']
      names.each { |value| expect(refusal('e2e_visual_store', value, id)).to eq(name_error) }
      ids.each { |value| expect(refusal('e2e_visual_store', 'e2e-visual-a', value)).to eq(source_error) }
      expect(refusal('e2e_visual_store', 'e2e-visual-a', id, 'x')).to eq('引数は name と source_account_id の 2 つだけを指定してください。')
      names.each { |value| expect(refusal('e2e_visual_purge', value)).to eq(name_error) }
      expect(refusal('e2e_visual_purge', 'e2e-visual-a', 'x')).to eq('引数は name の 1 つだけを指定してください。')
      expect(Account.where('name LIKE ?', 'e2e-visual-%').count).to eq(0)
      expect(new_rows.pluck(:result)).to eq(%w[started failed] * ((names.size * 2) + ids.size + 2))
    end
  end

  describe 'toybaco:e2e_visual_purge' do
    it '名前が完全に一致する目視用の店舗と所属と体験の記録を消し、複製した利用者は(source の所属が外れていても)消さずに数える' do
      fixture = source_store
      first, second = fixture[:administrators]
      account = created('e2e-visual-tour-4', fixture)
      neighbors = [create(:account, name: 'e2e-visual-tour-40'), create(:account, name: 'e2e-visual-tour')]
      # 複製の後に source の所属が外れた利用者(所属が目視用の店舗だけになる)も、E2E 用のメールアドレスでないので消さない。
      AccountUser.find_by!(account: fixture[:source], user: second).destroy!
      trial = Toybaco::GrowthTrial.create!(account_id: account.id, facts_revision: 'fixture', example_id: 1, starts_at: Time.now.utc,
                                           ends_at: 14.days.from_now)
      expect(run!('e2e_visual_purge', 'e2e-visual-tour-4'))
        .to eq(['TOYBACO_E2E_VISUAL_PURGE name=e2e-visual-tour-4 accounts=1 users=0 skipped_users=2'])
      expect([Account.exists?(account.id), AccountUser.where(account_id: account.id).count, Toybaco::GrowthTrial.exists?(trial.id)])
        .to eq([false, 0, false])
      expect([User.where(id: [first.id, second.id]).count, AccountUser.where(user_id: [first.id, second.id]).pluck(:account_id)])
        .to eq([2, [fixture[:source].id]])
      expect(Account.where(id: [fixture[:source], *neighbors].map(&:id)).count).to eq(3)
      # 一致する店舗が無ければ何も消さずに 0 件を出して正常に終わる(後片付けの再実行)。
      expect(run!('e2e_visual_purge', 'e2e-visual-tour-4'))
        .to eq(['TOYBACO_E2E_VISUAL_PURGE name=e2e-visual-tour-4 accounts=0 users=0 skipped_users=0'])
      expect(new_rows.pluck(:action, :result).last(4))
        .to eq([%w[rake.toybaco:e2e_visual_purge started], %w[rake.toybaco:e2e_visual_purge ok]] * 2)
    end

    it '名前が一致する店舗が 2 件あるか、選んだ後に名前が変われば、何も消さずに abort する' do
      fixture = source_store
      duplicates = create_list(:account, 2, name: 'e2e-visual-dup')
      expect(refusal('e2e_visual_purge', 'e2e-visual-dup')).to eq('name=e2e-visual-dup に一致する店舗が 2 件あるため削除しません。')
      account = created('e2e-visual-tour-5', fixture)
      allow(described_class).to receive(:named).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap { Account.find(account.id).update!(name: 'e2e-visual-tour-50') }
      end
      expect(refusal('e2e_visual_purge', 'e2e-visual-tour-5')).to eq("account=#{account.id} の名前か状態が選んだ後に変わったため削除しません。")
      expect([Account.where(id: duplicates.map(&:id)).count, AccountUser.where(account_id: account.id).count]).to eq([2, 2])
    end

    it 'E2E の後片付け(e2e_purge_accounts)は目視用の店舗に触れず、目視用の rake は E2E の店舗名を引数に取らない' do
      fixture = source_store
      account = created('e2e-visual-x', fixture)
      _, consent = Toybaco::Growth::FreeRegistration.new.register!(account_name: 'e2e-consent-r1-1', user_full_name: '規約 確認',
                                                                   email: 'qa+e2e-consent-r1-1@example.com', password: 'Passw0rd!x2Y')
      expect(run!('e2e_purge_accounts', 'e2e-consent-x'))
        .to eq(['TOYBACO_E2E_PURGE prefix=e2e-consent-x accounts=0 users=0 skipped_users=0 remaining=0',
                'TOYBACO_E2E_PURGE_GROWTH prefix=e2e-consent-x trials=0 identities=0 installations=0',
                'TOYBACO_E2E_PURGE_BILLING prefix=e2e-consent-x events=0 requests=0 inflight=0',
                'TOYBACO_E2E_PURGE_OPENING prefix=e2e-consent-x requests=0 events=0 notices=0'])
      expect(Toybaco::Ops::E2eConsent.accounts('e2e-consent-').map(&:id)).to eq([consent.id])
      expect(refusal('e2e_visual_purge', 'e2e-consent-r1-1')).to eq(name_error)
      expect(refusal('e2e_visual_store', 'e2e-consent-r1-1', fixture[:source].id.to_s)).to eq(name_error)
      expect(Account.where(id: [account.id, consent.id]).count).to eq(2)
      expect(run!('e2e_purge_accounts', 'e2e-consent-r1-1').first)
        .to eq('TOYBACO_E2E_PURGE prefix=e2e-consent-r1-1 accounts=1 users=1 skipped_users=0 remaining=0')
      expect([Account.exists?(account.id), AccountUser.where(account_id: account.id).count]).to eq([true, 2])
    end
  end

  # 受入(F1 / F2): purge は利用者を一切消さず、store と purge は作成票(internal_attributes の toybaco_e2e_visual)のある店舗だけを扱う。
  describe '利用者を消さないことと作成票' do
    it '複製した利用者は、E2E 用の形のメールアドレスで所属が目視用の店舗だけになっても消さず、削除の処理に渡すのは店舗だけ' do
      fixture = source_store
      tester = create(:user, name: '目視 試験者', email: 'qa+e2e-consent-tour@example.com')
      create(:account_user, account: fixture[:source], user: tester, role: :administrator)
      account = created('e2e-visual-tour-6', fixture)
      AccountUser.find_by!(account: fixture[:source], user: tester).destroy!
      performed = []
      allow(DeleteObjectJob).to receive(:new).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap do |job|
          allow(job).to receive(:perform).and_wrap_original do |perform, record, *rest|
            performed << record.class.name
            perform.call(record, *rest)
          end
        end
      end
      expect(run!('e2e_visual_purge', 'e2e-visual-tour-6'))
        .to eq(['TOYBACO_E2E_VISUAL_PURGE name=e2e-visual-tour-6 accounts=1 users=0 skipped_users=3'])
      expect(User.where(id: [tester, *fixture[:administrators]].map(&:id)).count).to eq(3)
      expect([performed, Account.exists?(account.id), AccountUser.where(user_id: tester.id).count]).to eq([['Account'], false, 0])
    end

    it '作成票の無い同名の店舗(実店舗)には、store が name_taken で断り、purge も消さない(店舗・所属・受信箱が残る)' do
      fixture = source_store
      real = create(:account, name: 'e2e-visual-real')
      owner = create(:user, name: '実店舗 管理者', account: real, role: :administrator)
      inbox = create(:inbox, account: real)
      footprint = lambda do
        [Account.count, AccountUser.where(account_id: real.id).pluck(:user_id), Inbox.where(account_id: real.id).pluck(:id),
         real.reload.internal_attributes]
      end
      saved = footprint.call
      expect(refusal('e2e_visual_store', 'e2e-visual-real', fixture[:source].id.to_s)).to eq(visual_line(real, 'refused', 'name_taken'))
      expect(refusal('e2e_visual_purge', 'e2e-visual-real'))
        .to eq("name=e2e-visual-real の店舗 account=#{real.id} は e2e_visual_store が作った店舗でない(作成票なし)ため削除しません。")
      expect(footprint.call).to eq(saved)
      expect(saved.values_at(1, 2)).to eq([[owner.id], [inbox.id]])
      expect(new_rows.pluck(:action, :result)).to eq([%w[rake.toybaco:e2e_visual_store started], %w[rake.toybaco:e2e_visual_store failed],
                                                      %w[rake.toybaco:e2e_visual_purge started], %w[rake.toybaco:e2e_visual_purge failed]])
    end

    it '作った店舗には作成票(source の id と UTC の作成時刻)が、契約・無料登録の段階と並んで残る' do
      fixture = source_store
      account = created('e2e-visual-tour-7', fixture)
      attrs = account.reload.internal_attributes
      marker = attrs['toybaco_e2e_visual']
      expect(marker.keys).to contain_exactly('source_account_id', 'created_at')
      expect(marker['source_account_id']).to eq(fixture[:source].id)
      expect(marker['created_at']).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
      expect([attrs.dig('toybaco_growth_registration', 'phase'), attrs.dig('toybaco_contract', 'plan_id')]).to eq(%w[active free])
      expect(described_class.marker?(account)).to be(true)
    end

    it '選んだ後に作成票が消えれば、行ロックして読み直して何も消さずに abort する' do
      fixture = source_store
      account = created('e2e-visual-tour-8', fixture)
      allow(described_class).to receive(:named).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap do
          fresh = Account.find(account.id)
          fresh.update!(internal_attributes: fresh.internal_attributes.except('toybaco_e2e_visual'))
        end
      end
      expect(refusal('e2e_visual_purge', 'e2e-visual-tour-8')).to eq("account=#{account.id} の名前か状態が選んだ後に変わったため削除しません。")
      expect([Account.exists?(account.id), AccountUser.where(account_id: account.id).count]).to eq([true, 2])
    end
  end

  # 受入(Grok 票): purge も store と同じ advisory lock を取り、ロックを待つ間に先の purge が消した店舗では落ちない。
  describe 'purge の advisory lock' do
    # 先の purge(同じ削除の手順)がロックを持って店舗を消し終えたことを、ロックを取った直後に同じ接続で表す。
    def purge_first(account)
      Toybaco::Ops::E2eConsent::Purge.children!([account.id])
      DeleteObjectJob.new.perform(Account.find(account.id))
    end

    it 'purge も store と同じ advisory lock を、店舗を行ロックして読み直す前に取る' do
      account = created('e2e-visual-tour-9', source_store)
      events = []
      allow(ActiveRecord::Base.connection).to receive(:execute).and_wrap_original do |original, sql, *rest, **options|
        events << :advisory_lock if sql == described_class::LOCK_SQL
        original.call(sql, *rest, **options)
      end
      allow(Toybaco::Ops::E2eConsent::WriteGuard).to receive(:relock!).and_wrap_original do |original, *arguments, **options, &block|
        events << :relock
        original.call(*arguments, **options, &block)
      end
      expect(run!('e2e_visual_purge', 'e2e-visual-tour-9').first).to start_with('TOYBACO_E2E_VISUAL_PURGE name=e2e-visual-tour-9 accounts=1 ')
      expect([events, Account.exists?(account.id)]).to eq([%i[advisory_lock relock], false])
    end

    it 'ロックを待つ間に先の purge が店舗を消し終えていれば、読み直しで落ちずに accounts=0 で正常に終わる' do
      account = created('e2e-visual-tour-10', source_store)
      allow(ActiveRecord::Base.connection).to receive(:execute).and_wrap_original do |original, sql, *rest, **options|
        original.call(sql, *rest, **options).tap { purge_first(account) if sql == described_class::LOCK_SQL }
      end
      expect(run!('e2e_visual_purge', 'e2e-visual-tour-10'))
        .to eq(['TOYBACO_E2E_VISUAL_PURGE name=e2e-visual-tour-10 accounts=0 users=0 skipped_users=0'])
      expect([Account.exists?(account.id), new_rows.pluck(:result).last(2)]).to eq([false, %w[started ok]])
    end
  end
end
