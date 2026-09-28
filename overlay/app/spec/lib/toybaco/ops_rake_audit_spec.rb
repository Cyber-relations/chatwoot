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
end
