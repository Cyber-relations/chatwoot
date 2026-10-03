# frozen_string_literal: true

require 'rails_helper'
require 'active_support/testing/stream'

Rails.application.load_tasks unless Rake::Task.task_defined?('toybaco:audit_tail')

# 置き場所は他の overlay spec(spec/lib/toybaco/*_spec.rb)と揃え、rspec manifest の名簿で固定している。
RSpec.describe Toybaco::Ops::RakeAudit do # rubocop:disable RSpec/SpecFilePathFormat
  include ActiveSupport::Testing::Stream

  let(:empty_digest) { Toybaco::Ops::Audit.params_digest({}) }
  let!(:baseline) { Toybaco::OperatorAction.maximum(:id).to_i }

  # rake の監査行は別の DB セッションで確定させるため、transactional test のロールバックでは消えない。
  after { delete_committed_rows(baseline) }

  around { |example| with_modified_env(TOYBACO_OPS_ACTOR: nil, TOYBACO_OPS_SOURCE: nil) { example.run } }

  def new_rows
    Toybaco::OperatorAction.where('id > ?', baseline).order(:id)
  end

  # 別セッションで確定した監査行の後片付け。監査表は追記専用トリガで DELETE を拒むため、test DB の postgres(superuser)で
  # session_replication_role = replica にしてトリガを止めてから消す。本番のアプリユーザーは superuser ではないので効かない。
  def delete_committed_rows(after_id)
    connection = ActiveRecord::Base.connection_db_config.new_connection
    connection.execute('SET session_replication_role = replica')
    connection.execute("DELETE FROM toybaco_operator_actions WHERE id > #{Integer(after_id)}")
  ensure
    connection&.disconnect!
  end

  def tail(limit)
    Rake::Task['toybaco:audit_tail'].execute(Rake::TaskArguments.new([:limit], [limit]))
  end

  it 'Rake::Task に組み込まれている' do
    expect(Rake::Task.ancestors).to include(described_class)
  end

  it 'toybaco:plan_status は既定の actor(unknown)と source(rake:unspecified)で started と ok の 2 行を残す' do
    account = create(:account)
    expect { Rake::Task['toybaco:plan_status'].execute }.to output(/##{account.id} /).to_stdout
    expect(new_rows.pluck(:actor_kind, :actor_id, :action, :result, :source, :target_type, :params_digest)).to eq(
      [['rake', 'unknown', 'rake.toybaco:plan_status', 'started', 'rake:unspecified', nil, empty_digest],
       ['rake', 'unknown', 'rake.toybaco:plan_status', 'ok', 'rake:unspecified', nil, empty_digest]]
    )
  end

  it 'ops-rake workflow が渡した TOYBACO_OPS_SOURCE と TOYBACO_OPS_ACTOR を記録する' do
    create(:account)
    with_modified_env(TOYBACO_OPS_SOURCE: 'ops-rake-1-1', TOYBACO_OPS_ACTOR: 'ops-lead') do
      expect { Rake::Task['toybaco:plan_status'].execute }.to output.to_stdout
    end
    expect(new_rows.pluck(:actor_id, :source, :result)).to eq([%w[ops-lead ops-rake-1-1 started], %w[ops-lead ops-rake-1-1 ok]])
  end

  it 'TOYBACO_OPS_ACTOR / TOYBACO_OPS_SOURCE の形が合わなければ、値を出さずに started も書かずに失敗する' do
    create(:account)
    [{ TOYBACO_OPS_ACTOR: 'ops lead' }, { TOYBACO_OPS_ACTOR: 'a' * 40 }, { TOYBACO_OPS_ACTOR: "ops-lead\nforged" },
     { TOYBACO_OPS_SOURCE: 'ops rake' }, { TOYBACO_OPS_SOURCE: 's' * 129 }, { TOYBACO_OPS_SOURCE: "ops-rake-1-1\nforged" }].each do |env|
      error = nil
      with_modified_env(env) do
        expect { Rake::Task['toybaco:plan_status'].execute }.to raise_error(ArgumentError) { |raised| error = raised }
      end
      expect(error.message).to start_with(env.keys.first.to_s)
      expect(error.message).not_to include(env.values.first)
    end
    expect(new_rows).to be_empty
  end

  it '宣言していない余剰引数(extras)も digest に含め、extras が無ければ従来の digest のままにする' do
    capture(:stdout) { Rake::Task['toybaco:audit_tail'].execute(Rake::TaskArguments.new([:limit], %w[5 x y])) }
    capture(:stdout) { tail('5') }
    expect(new_rows.where(result: 'started').pluck(:params_digest)).to eq(
      [Toybaco::Ops::Audit.params_digest({ 'limit' => '5', '_extras' => %w[x y] }), Toybaco::Ops::Audit.params_digest({ 'limit' => '5' })]
    )
  end

  it 'rake -n(dry-run)では本体を実行せず、監査行も書かない' do
    create(:account)
    options = Rake.application.options
    original = [options.dryrun, options.trace_output]
    options.dryrun = true
    options.trace_output = StringIO.new
    expect { Rake::Task['toybaco:plan_status'].execute }.not_to output.to_stdout
    expect(options.trace_output.string).to include('** Execute (dry run) toybaco:plan_status')
    expect(new_rows).to be_empty
  ensure
    options.dryrun, options.trace_output = original
  end

  it 'タスクの例外は failed を書いてから再送出する(検査用のタスクは spec の中だけで定義する)' do
    Rake::Task.define_task('toybaco:audit_probe_fail') { raise 'boom' }
    expect { Rake::Task['toybaco:audit_probe_fail'].execute }.to raise_error(RuntimeError, 'boom')
    expect(new_rows.pluck(:action, :result)).to eq([%w[rake.toybaco:audit_probe_fail started], %w[rake.toybaco:audit_probe_fail failed]])
  ensure
    Rake::Task['toybaco:audit_probe_fail'].clear
  end

  it 'toybaco: 以外(db: など)のタスクは包まない' do
    Rake::Task.define_task('db:audit_probe') { nil }
    Rake::Task['db:audit_probe'].execute
    expect(new_rows).to be_empty
  ensure
    Rake::Task['db:audit_probe'].clear
  end

  describe 'toybaco:audit_tail' do
    it '直近の行を id の新しい順に、固定順の key=value で 1 行ずつ出す' do
      account = create(:account)
      older = Toybaco::Ops::Audit.record!(actor_kind: 'super_admin', actor_id: '7', action: 'super_admin.account.update', target: account,
                                          params: { 'id' => account.id.to_s }, result: 'ok', source: 'req-1')
      newer = Toybaco::Ops::Audit.record!(actor_kind: 'workflow', actor_id: 'ops-lead', action: 'workflow.fixture', result: 'rejected')
      lines = capture(:stdout) { tail('3') }.lines(chomp: true)
      started = new_rows.where(action: 'rake.toybaco:audit_tail').first
      jst = ->(row) { row.created_at.getlocal('+09:00').iso8601 }
      expect(lines).to eq(
        ["id=#{started.id} created_at=#{jst.call(started)} actor_kind=rake actor_id=unknown action=rake.toybaco:audit_tail target=- " \
         "result=started source=rake:unspecified params_digest=#{Toybaco::Ops::Audit.params_digest({ 'limit' => '3' })}",
         "id=#{newer.id} created_at=#{jst.call(newer)} actor_kind=workflow actor_id=ops-lead action=workflow.fixture target=- " \
         'result=rejected source=- params_digest=-',
         "id=#{older.id} created_at=#{jst.call(older)} actor_kind=super_admin actor_id=7 action=super_admin.account.update " \
         "target=Account##{account.id} result=ok source=req-1 params_digest=#{older.params_digest}"]
      )
      keys = %w[id created_at actor_kind actor_id action target result source params_digest]
      expect(lines.map { |line| line.split.map { |pair| pair.split('=', 2).first } }).to all(eq(keys))
    end

    it '件数は省略時 50 件で、1 と 999 を受け付ける' do
      55.times { |index| Toybaco::Ops::Audit.record!(actor_kind: 'job', actor_id: "fixture-#{index}", action: 'job.fixture', result: 'ok') }
      expect(capture(:stdout) { tail(nil) }.lines.length).to eq(50)
      expect(capture(:stdout) { tail('') }.lines.length).to eq(50)
      expect(capture(:stdout) { tail('1') }.lines.length).to eq(1)
      visible = Toybaco::OperatorAction.count + 1
      expect(capture(:stdout) { tail('999') }.lines.length).to eq([visible, 999].min)
    end

    it '件数が 0・1000・数字以外なら abort し、failed を残す' do
      %w[0 1000 x].each do |limit|
        expect { tail(limit) }.to raise_error(SystemExit).and output("件数は 1〜999 の整数で指定してください。\n").to_stderr
      end
      expect(new_rows.pluck(:action, :result)).to eq([%w[rake.toybaco:audit_tail started], %w[rake.toybaco:audit_tail failed]] * 3)
    end
  end

  describe 'toybaco:ops_flag' do
    # 実装の定数に頼らず、機能側が JSON の boolean で判定する 5 つのフラグをここで固定する。
    let(:flags) do
      %w[TOYBACO_OPS_DIGEST_ENABLED TOYBACO_OPS_CONSOLE_ENABLED TOYBACO_SUPPORT_REPORTS_ENABLED TOYBACO_SUPPORT_ENABLED
         TOYBACO_SUPPORT_AI_ENABLED]
    end
    let(:name_error) { "フラグ名は #{flags.join(' / ')} のいずれかを指定してください。\n" }
    let(:value_error) { "値は true か false を指定してください。\n" }
    let(:extras_error) { "引数はフラグ名と値の 2 つだけを指定してください(1 回に切り替えるフラグは 1 つ)。\n" }

    def run_ops_flag(*values)
      Rake::Task['toybaco:ops_flag'].execute(Rake::TaskArguments.new(%i[name value], values))
    end

    # 成功するはずの呼び出し。想定外の abort(SystemExit)は RSpec の実行全体を止めるため、この例の失敗に置き換える。
    def ops_flag(*values)
      run_ops_flag(*values)
    rescue SystemExit
      raise RSpec::Expectations::ExpectationNotMetError, "toybaco:ops_flag[#{values.join(',')}] が abort しました"
    end

    def config_rows
      InstallationConfig.unscoped.order(:id).map { |row| [row.id, row.name, row.value, row.locked, row.updated_at] }
    end

    # 出力の期待値。切り替えの結果の 1 行に、5 つのフラグの現在値の 5 行(行が無ければ unset)が続く。
    def flag_output(line, states = {})
      [line, *flags.map { |flag| "TOYBACO_OPS_FLAG_STATE name=#{flag} value=#{states.fetch(flag, 'unset')}" }].map { |text| "#{text}\n" }.join
    end

    it '許可一覧は機能側(ダイジェスト・店舗一覧・利用者からの報告・使い方サポートの入口と AI 回答)が判定するフラグと一致する' do
      expect(Toybaco::Ops::OpsFlag::OPS_FLAGS).to eq(flags)
      expect(flags).to include(Toybaco::Ops::Digest::FLAG, Toybaco::Ops::Console::FLAG)
      allow(Toybaco::Ops::OpsFlag).to receive(:enabled?).and_call_original
      Toybaco::Support::Reports.available?
      expect(Toybaco::Ops::OpsFlag).to have_received(:enabled?).with('TOYBACO_SUPPORT_REPORTS_ENABLED')
    end

    it 'true で JSON の boolean true を locked: true で保存し、読み手(DB 直読)が有効と読む' do
      states = {}
      flags.each do |name|
        states[name] = 'true'
        expect { ops_flag(name, 'true') }.to output(flag_output("TOYBACO_OPS_FLAG name=#{name} value=true previous=unset", states)).to_stdout
        expect(InstallationConfig.find_by(name: name)).to have_attributes(value: true, locked: true)
        expect(Toybaco::Ops::OpsFlag.enabled?(name)).to be(true)
      end
      expect(Toybaco::Ops::Console.enabled?).to be(true)
    end

    it 'false で JSON の boolean false を保存し、読み手(DB 直読)が無効と読む' do
      states = {}
      flags.each do |name|
        capture(:stdout) { ops_flag(name, 'true') }
        states[name] = 'false'
        expect { ops_flag(name, 'false') }.to output(flag_output("TOYBACO_OPS_FLAG name=#{name} value=false previous=true", states)).to_stdout
        expect(InstallationConfig.find_by(name: name)).to have_attributes(value: false, locked: true)
        expect(Toybaco::Ops::OpsFlag.enabled?(name)).to be(false)
      end
      expect(Toybaco::Ops::Console.enabled?).to be(false)
    end

    it 'SuperAdmin 画面で保存された文字列の "true" を boolean に置き換え、文字列は "true" / "false" だけ引用符付きで出して他は中身を出さない' do
      InstallationConfig.create!(name: 'TOYBACO_OPS_CONSOLE_ENABLED', value: 'true', locked: false)
      InstallationConfig.create!(name: 'TOYBACO_OPS_DIGEST_ENABLED', value: 'x' * 100, locked: false)
      InstallationConfig.create!(name: 'TOYBACO_SUPPORT_REPORTS_ENABLED', value: 'true', locked: false)
      expect(Toybaco::Ops::Console.enabled?).to be(false)
      expect { ops_flag('TOYBACO_OPS_CONSOLE_ENABLED', 'true') }.to output(
        flag_output('TOYBACO_OPS_FLAG name=TOYBACO_OPS_CONSOLE_ENABLED value=true previous="true"',
                    'TOYBACO_OPS_DIGEST_ENABLED' => 'non_boolean', 'TOYBACO_OPS_CONSOLE_ENABLED' => 'true',
                    'TOYBACO_SUPPORT_REPORTS_ENABLED' => '"true"')
      ).to_stdout
      expect(Toybaco::Ops::Console.enabled?).to be(true)
      expect { ops_flag('TOYBACO_OPS_DIGEST_ENABLED', 'false') }.to output(
        flag_output('TOYBACO_OPS_FLAG name=TOYBACO_OPS_DIGEST_ENABLED value=false previous=non_boolean',
                    'TOYBACO_OPS_DIGEST_ENABLED' => 'false', 'TOYBACO_OPS_CONSOLE_ENABLED' => 'true', 'TOYBACO_SUPPORT_REPORTS_ENABLED' => '"true"')
      ).to_stdout
      expect(InstallationConfig.find_by(name: 'TOYBACO_SUPPORT_REPORTS_ENABLED')).to have_attributes(value: 'true', locked: false)
    end

    it '保存した行は locked: true で SuperAdmin の画面(InstallationConfig.editable)に出ず、locked: false の既存行も true に上書きする' do
      InstallationConfig.create!(name: 'TOYBACO_OPS_CONSOLE_ENABLED', value: true, locked: false)
      expect(InstallationConfig.editable.where(name: 'TOYBACO_OPS_CONSOLE_ENABLED')).to exist
      capture(:stdout) do
        ops_flag('TOYBACO_OPS_CONSOLE_ENABLED', 'true')
        ops_flag('TOYBACO_OPS_DIGEST_ENABLED', 'false')
      end
      expect(InstallationConfig.where(name: flags).pluck(:name, :locked)).to contain_exactly(
        ['TOYBACO_OPS_CONSOLE_ENABLED', true], ['TOYBACO_OPS_DIGEST_ENABLED', true]
      )
      expect(InstallationConfig.editable.where(name: flags)).to be_empty
    end

    it '読み直しが指定の boolean にならなければ abort して transaction を rollback し、保存しない(監査は failed)' do
      InstallationConfig.create!(name: 'TOYBACO_OPS_DIGEST_ENABLED', value: false, locked: true)
      before_rows = config_rows
      # 読み直しの 2 つの条件(読み手の判定と生値)をそれぞれ崩す。行の書き込み自体は本物のまま。
      allow(Toybaco::Ops::OpsFlag).to receive(:current).and_call_original
      allow(Toybaco::Ops::OpsFlag).to receive(:current).with('TOYBACO_OPS_DIGEST_ENABLED').and_return('true')
      allow(Toybaco::Ops::OpsFlag).to receive(:current).with('TOYBACO_OPS_CONSOLE_ENABLED').and_return(nil)
      [%w[TOYBACO_OPS_DIGEST_ENABLED true], %w[TOYBACO_OPS_CONSOLE_ENABLED false]].each do |name, value|
        message = "#{name} の読み直しが boolean の #{value} にならないため保存しません。installation_configs を確認してください。\n"
        expect { run_ops_flag(name, value) }.to raise_error(SystemExit).and output(message).to_stderr
      end
      expect(config_rows).to eq(before_rows)
      expect(new_rows.pluck(:action, :result)).to eq([%w[rake.toybaco:ops_flag started], %w[rake.toybaco:ops_flag failed]] * 2)
    end

    it 'Ruby から boolean の true / false を渡しても(文字列でないので)abort し、保存しない' do
      [true, false].each do |value|
        expect { run_ops_flag('TOYBACO_OPS_DIGEST_ENABLED', value) }.to raise_error(SystemExit).and output(value_error).to_stderr
      end
      expect(InstallationConfig.find_by(name: 'TOYBACO_OPS_DIGEST_ENABLED')).to be_nil
    end

    it '許可一覧にないフラグ名(大文字小文字違い・Symbol・空を含む)は abort し、installation_configs を変えずに failed を残す' do
      InstallationConfig.create!(name: 'TOYBACO_GROWTH_NOTICES_ENABLED', value: false, locked: false)
      before_rows = config_rows
      names = ['TOYBACO_GROWTH_NOTICES_ENABLED', 'toybaco_ops_digest_enabled', 'Toybaco_Ops_Console_Enabled', ' TOYBACO_OPS_DIGEST_ENABLED',
               :TOYBACO_OPS_DIGEST_ENABLED, '', nil]
      names.each do |name|
        expect { run_ops_flag(name, 'true') }.to raise_error(SystemExit).and output(name_error).to_stderr
      end
      expect(config_rows).to eq(before_rows)
      expect(new_rows.pluck(:action, :result)).to eq([%w[rake.toybaco:ops_flag started], %w[rake.toybaco:ops_flag failed]] * names.size)
    end

    it "値が 'true' / 'false' 以外('TRUE'・'1' など)や余分な引数があれば abort し、保存済みの値を変えない" do
      capture(:stdout) { ops_flag('TOYBACO_SUPPORT_REPORTS_ENABLED', 'false') }
      before_rows = config_rows
      ['TRUE', 'True', 'FALSE', '1', '0', 'yes', 'true ', '', nil].each do |value|
        expect { run_ops_flag('TOYBACO_SUPPORT_REPORTS_ENABLED', value) }.to raise_error(SystemExit).and output(value_error).to_stderr
      end
      extras = %w[TOYBACO_SUPPORT_REPORTS_ENABLED true TOYBACO_OPS_CONSOLE_ENABLED true]
      expect { run_ops_flag(*extras) }.to raise_error(SystemExit).and output(extras_error).to_stderr
      expect(config_rows).to eq(before_rows)
      expect(Toybaco::Ops::OpsFlag.current('TOYBACO_SUPPORT_REPORTS_ENABLED')).to be(false)
    end

    it '監査行に started と ok が残り、params_digest は name と value の digest と一致する' do
      capture(:stdout) { ops_flag('TOYBACO_OPS_DIGEST_ENABLED', 'true') }
      digest = Toybaco::Ops::Audit.params_digest({ 'name' => 'TOYBACO_OPS_DIGEST_ENABLED', 'value' => 'true' })
      expect(new_rows.pluck(:actor_kind, :actor_id, :action, :result, :source, :target_type, :params_digest)).to eq(
        [['rake', 'unknown', 'rake.toybaco:ops_flag', 'started', 'rake:unspecified', nil, digest],
         ['rake', 'unknown', 'rake.toybaco:ops_flag', 'ok', 'rake:unspecified', nil, digest]]
      )
    end
  end

  describe 'toybaco:legal_consents' do
    let(:account) { create(:account) }
    let(:failed_rows) { [%w[rake.toybaco:legal_consents started], %w[rake.toybaco:legal_consents failed]] }

    def run_legal_consents(*values)
      Rake::Task['toybaco:legal_consents'].execute(Rake::TaskArguments.new([:account_id], values))
    end

    # 成功するはずの呼び出し。想定外の abort(SystemExit)は RSpec の実行全体を止めるため、この例の失敗に置き換える。
    def legal_consents(*values)
      run_legal_consents(*values)
    rescue SystemExit
      raise RSpec::Expectations::ExpectationNotMetError, "toybaco:legal_consents[#{values.join(',')}] が abort しました"
    end

    # 期待する 1 件 1 行(項目は route・terms_version・accepted_at・user_id・session・stripe_consent の固定順)。
    def consent_lines(rows)
      rows.map do |row|
        route, version, accepted_at, user_id, session, stripe_consent = row
        "TOYBACO_LEGAL_CONSENT account=#{account.id} route=#{route} terms_version=#{version} accepted_at=#{accepted_at} " \
          "user_id=#{user_id} session=#{session} stripe_consent=#{stripe_consent}"
      end
    end

    it '記録が無ければ件数 0 の集計行だけを出し、監査行に started と ok を残す(params_digest は account_id の digest)' do
      expect { legal_consents(account.id.to_s) }.to output("TOYBACO_LEGAL_CONSENTS account=#{account.id} count=0 routes=-\n").to_stdout
      digest = Toybaco::Ops::Audit.params_digest({ 'account_id' => account.id.to_s })
      expect(new_rows.pluck(:actor_kind, :actor_id, :action, :result, :source, :target_type, :params_digest)).to eq(
        [['rake', 'unknown', 'rake.toybaco:legal_consents', 'started', 'rake:unspecified', nil, digest],
         ['rake', 'unknown', 'rake.toybaco:legal_consents', 'ok', 'rake:unspecified', nil, digest]]
      )
    end

    it '開通と 4 経路の記録を 1 件 1 行で出し、Session は先頭 8 字・利用者は id だけを出して、記録を書き換えない' do
      user = create(:user, name: '規約 確認子', email: 'consent-owner@example.com')
      opening = "cs_test_#{'a1B2' * 10}"
      purchase = "cs_live_#{'c3D4' * 10}"
      account.update!(internal_attributes: { 'toybaco_stripe_customer_id' => 'cus_LegalConsentCustomer1' })
      # 書き手と同じ正本(LegalTerms.record!)で記録する。growth_purchase の同意日時は +09:00 で渡し、UTC で読めることを確かめる。出力の経路は _ を - にした表記。
      [['opening_checkout', '2026-09-25.1', '2026-09-25T01:02:03Z', { session_id: opening, stripe_consent: 'accepted' }],
       ['growth_purchase', '2026-09-25.1', '2026-09-26T02:03:04+09:00', { user_id: user.id, session_id: purchase, stripe_consent: 'accepted' }],
       ['free_registration', '2026-09-06.1', '2026-09-27T03:04:05Z', { user_id: user.id }],
       ['trial', '2026-09-25.1', '2026-09-28T04:05:06Z', { user_id: user.id }],
       ['managed_auto', '2026-09-25.1', '2026-09-29T05:06:07Z', { user_id: user.id }],
       ['managed_auto', '2026-09-25.1', '2026-09-30T06:07:08Z', { user_id: user.id }]].each do |route, version, accepted_at, details|
        Toybaco::LegalTerms.record!(account, route: route, accepted_at: accepted_at, terms_version: version, **details)
      end
      saved = account.reload.attributes.slice('internal_attributes', 'updated_at')
      output = capture(:stdout) { legal_consents(account.id.to_s) }
      expect(output.lines(chomp: true)).to eq(
        consent_lines([%w[opening-checkout 2026-09-25.1 2026-09-25T01:02:03Z - cs_test_… accepted],
                       ['growth-purchase', '2026-09-25.1', '2026-09-25T17:03:04Z', user.id, 'cs_live_…', 'accepted'],
                       ['free-registration', '2026-09-06.1', '2026-09-27T03:04:05Z', user.id, '-', '-'],
                       ['trial', '2026-09-25.1', '2026-09-28T04:05:06Z', user.id, '-', '-'],
                       ['managed-auto', '2026-09-25.1', '2026-09-29T05:06:07Z', user.id, '-', '-'],
                       ['managed-auto', '2026-09-25.1', '2026-09-30T06:07:08Z', user.id, '-', '-']]) +
        ["TOYBACO_LEGAL_CONSENTS account=#{account.id} count=6 " \
         'routes=opening-checkout:1,growth-purchase:1,free-registration:1,managed-auto:2,trial:1']
      )
      expect(output).not_to include(user.email, user.name, opening, purchase, opening[0, 9], purchase[0, 9], 'cus_', '@')
      expect(account.reload.attributes.slice('internal_attributes', 'updated_at')).to eq(saved)
    end

    it '記録の値が LegalTerms の形に合わなければ中身を出さずに invalid と出し、8 字以下の Session は cs_ だけを出す' do
      leak = 'leak@example.com'
      malformed = { 'route' => leak, 'terms_version' => leak, 'accepted_at' => leak, 'user_id' => leak, 'session_id' => "cs_#{leak}",
                    'stripe_consent' => leak }
      short_session = { 'route' => 'trial', 'terms_version' => '2026-09-25.1', 'accepted_at' => '2026-09-25T01:02:03Z', 'user_id' => 0,
                        'session_id' => 'cs_a1b2c', 'stripe_consent' => nil }
      account.update!(internal_attributes: { 'toybaco_legal_consents' => [malformed, short_session, leak] })
      output = capture(:stdout) { legal_consents(account.id.to_s) }
      expect(output.lines(chomp: true)).to eq(
        consent_lines([%w[invalid invalid invalid invalid invalid invalid], %w[trial 2026-09-25.1 2026-09-25T01:02:03Z invalid cs_… -],
                       %w[invalid invalid invalid invalid invalid invalid]]) +
        ["TOYBACO_LEGAL_CONSENTS account=#{account.id} count=3 routes=trial:1,invalid:2"]
      )
      expect(output).not_to include('leak', '@', 'a1b2c')
    end

    it '記録が配列でなければ(正本の LegalTerms.records が拒む)何も出さずに失敗し、failed を残す' do
      account.update!(internal_attributes: { 'toybaco_legal_consents' => 'leak@example.com' })
      expect { run_legal_consents(account.id.to_s) }.to raise_error(ArgumentError, 'invalid consent history').and output('').to_stdout
      expect(new_rows.pluck(:action, :result)).to eq(failed_rows)
    end

    it 'account_id が 1 以上の整数の文字列でなければ(引数なし・0・先頭 0・11 桁・空白や改行・数字以外・空・nil・Integer・余剰引数)入力を出さずに abort し、failed を残す' do
      format_error = "account_id は 1 以上の整数で指定してください。\n"
      values = ['0', '012', '12345678901', ' 12', '12 ', "12\n", '1e3', '-1', 'abc', '', nil, 12]
      expect { run_legal_consents }.to raise_error(SystemExit).and output(format_error).to_stderr
      values.each do |value|
        expect { run_legal_consents(value) }.to raise_error(SystemExit).and output(format_error).to_stderr
      end
      expect { run_legal_consents(account.id.to_s, 'x') }.to raise_error(SystemExit)
        .and output("引数は account_id の 1 つだけを指定してください。\n").to_stderr
      expect(new_rows.pluck(:action, :result)).to eq(failed_rows * (values.size + 2))
    end

    it '存在しない account は id だけを出して abort し、failed を残す(int の範囲を超える 10 桁も not found として扱う)' do
      missing = (Account.maximum(:id).to_i + 1).to_s
      [missing, '9999999999'].each do |value|
        expect { run_legal_consents(value) }.to raise_error(SystemExit).and output("account=#{value} が見つかりません。\n").to_stderr
      end
      expect(new_rows.pluck(:action, :result)).to eq(failed_rows * 2)
    end
  end
end
