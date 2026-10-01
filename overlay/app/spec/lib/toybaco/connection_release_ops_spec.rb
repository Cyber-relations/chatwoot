# frozen_string_literal: true

require 'rails_helper'
require 'active_support/testing/stream'

Rails.application.load_tasks unless Rake::Task.task_defined?('toybaco:connection_release_show')

# メール接続の開放を進める運営 rake(toybaco:connection_release_* と toybaco:connection_handoff_mail)。記録の書き込み、読み手
# (Gmail / Microsoft の public_decision と Handoff::MailGateway)と同じ判定での読み直し、staging 限定の後片付け、監査行を確かめる。
# client ID・secret は fixture の値で、出力に出ないことも確かめる。
# 置き場所は他の overlay spec(spec/lib/toybaco/*_spec.rb)と揃え、rspec manifest の名簿で固定している。
RSpec.describe Toybaco::Ops::ConnectionReleaseOps do # rubocop:disable RSpec/SpecFilePathFormat
  include ActiveSupport::Testing::Stream

  let!(:baseline) { Toybaco::OperatorAction.maximum(:id).to_i }
  let(:observed) { '2026-09-29T09:00:00Z' }
  let(:expires) { '2027-09-29T00:00:00Z' }
  let(:all_checks) { 'authorization.callback.receive.reply.disconnect.tenant_isolation' }
  let(:gmail_identity) do
    { 'application_id' => 'fixture-gmail-client-id',
      'scope_digest' => Toybaco::ConnectionRelease.scope_digest(Toybaco::Connections::GmailApi::SCOPES) }
  end
  let(:microsoft_approval) do
    { 'approval' => { 'application_id' => 'fixture-microsoft-client-id',
                      'scope_digest' => Toybaco::ConnectionRelease.scope_digest(Toybaco::Connections::MicrosoftApi::SCOPES),
                      'status' => 'approved', 'evidence_ref' => 'approval-9', 'observed_at' => observed } }
  end
  let(:secrets) do
    ['fixture-gmail-client-id', 'fixture-gmail-secret-value', 'fixture-microsoft-client-id', 'fixture-microsoft-secret-value',
     gmail_identity['scope_digest'], Toybaco::ConnectionRelease.scope_digest(Toybaco::Connections::MicrosoftApi::SCOPES)]
  end

  around do |example|
    travel_to(Time.utc(2026, 9, 30, 3)) do
      with_modified_env(TOYBACO_DEPLOYMENT_ENVIRONMENT: 'staging', FRONTEND_URL: 'https://app.staging.toybaco.jp',
                        TOYBACO_OPS_ACTOR: nil, TOYBACO_OPS_SOURCE: nil) { example.run }
    end
  end

  before do
    { 'TOYBACO_GMAIL_CLIENT_ID' => 'fixture-gmail-client-id', 'TOYBACO_GMAIL_CLIENT_SECRET' => 'fixture-gmail-secret-value',
      'TOYBACO_MICROSOFT_CLIENT_ID' => 'fixture-microsoft-client-id',
      'TOYBACO_MICROSOFT_CLIENT_SECRET' => 'fixture-microsoft-secret-value' }.each do |name, value|
      InstallationConfig.create!(name: name, value: value, locked: false)
    end
    GlobalConfig.clear_cache
  end

  # rake の監査行は別の DB セッションで確定させるため、transactional test のロールバックでは消えない(ops_rake_audit_spec と同じ後片付け)。
  after do
    GlobalConfig.clear_cache
    delete_committed_rows(baseline)
  end

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

  # abort して何も保存しないことを確かめ、abort の文を返す。
  def expect_refusal(name, *values)
    before_rows = config_rows
    message = capture(:stderr) { expect { run_task(name, *values) }.to raise_error(SystemExit) }
    expect(config_rows).to eq(before_rows)
    message.chomp
  end

  def config_rows
    InstallationConfig.unscoped.order(:id).map { |row| [row.id, row.name, row.value, row.locked, row.updated_at] }
  end

  def releases
    InstallationConfig.find_by(name: 'TOYBACO_CONNECTION_RELEASES')&.value
  end

  def record(kind, provider = 'gmail_rest')
    releases.dig('staging', provider, kind)
  end

  def open!(provider = 'gmail_rest')
    run!('connection_release_approve', provider, 'approval', 'approval-1', observed, 'none')
    run!('connection_release_approve', provider, 'qualification', 'casa-1', observed, expires)
    run!('connection_release_smoke', provider, 'smoke-1', observed, all_checks)
  end

  # show の出力の期待値。records で approval / qualification / smoke の行の内容と disabled の値を指定する(既定は記録なし)。
  def state_lines(reason, available: false, **records)
    ["TOYBACO_CONNECTION_RELEASE provider=gmail_rest environment=staging available=#{available} reason=#{reason}",
     *%i[approval qualification smoke].map do |kind|
       "TOYBACO_CONNECTION_RELEASE_RECORD provider=gmail_rest kind=#{kind} #{records.fetch(kind, 'recorded=false')}"
     end,
     "TOYBACO_CONNECTION_RELEASE_RECORD provider=gmail_rest kind=disabled value=#{records.fetch(:disabled, 'unset')}"]
  end

  def expect_no_secrets(lines)
    secrets.each { |secret| expect(lines.join("\n")).not_to include(secret) }
  end

  describe 'toybaco:connection_release_show' do
    it '読み手の判定と記録の有無を 1 行ずつ出し、Microsoft も同じ形で出す' do
      expect(run!('connection_release_show', 'gmail_rest')).to eq(state_lines('review_pending'))
      lines = run!('connection_release_show', 'microsoft_graph')
      expect(lines.first).to eq('TOYBACO_CONNECTION_RELEASE provider=microsoft_graph environment=staging available=false reason=review_pending')
      expect(lines.size).to eq(5)
      expect(new_rows.pluck(:action, :result)).to eq([%w[rake.toybaco:connection_release_show started],
                                                      %w[rake.toybaco:connection_release_show ok]] * 2)
    end

    it 'secret が無い設定は読み手と同じ application_unconfigured と出し、環境が不明なら unknown と出す' do
      InstallationConfig.find_by(name: 'TOYBACO_GMAIL_CLIENT_SECRET').update!(value: '')
      GlobalConfig.clear_cache
      expect(run!('connection_release_show', 'gmail_rest').first).to end_with('available=false reason=application_unconfigured')
      with_modified_env(TOYBACO_DEPLOYMENT_ENVIRONMENT: 'development') do
        expect(run!('connection_release_show', 'microsoft_graph').first).to eq(
          'TOYBACO_CONNECTION_RELEASE provider=microsoft_graph environment=unknown available=false reason=environment_unknown'
        )
      end
    end

    it '許可一覧にない provider(担当者依頼のキー・大文字・Symbol・空)と余分な引数は abort し、failed を残す' do
      message = 'provider は gmail_rest / microsoft_graph のいずれかを指定してください。'
      ['gmail', 'Gmail_Rest', :gmail_rest, '', nil].each do |provider|
        expect(expect_refusal('connection_release_show', provider)).to eq(message)
      end
      expect(expect_refusal('connection_release_show', 'gmail_rest', 'x')).to eq('引数は provider の 1 つだけを指定してください。')
      expect(new_rows.pluck(:result)).to eq(%w[started failed] * 6)
    end
  end

  describe 'toybaco:connection_release_approve' do
    it '現在の client ID と scope digest で approval を記録し、判定が qualification_pending へ進む(期限 none は期限なし)' do
      lines = run!('connection_release_approve', 'gmail_rest', 'approval', 'google-approval-1', observed, 'none')
      approval = "recorded=true status=approved evidence_ref=google-approval-1 observed_at=#{observed} expires_at=none identity=match"
      expect(lines).to eq(['TOYBACO_CONNECTION_RELEASE_APPROVE provider=gmail_rest environment=staging kind=approval previous=absent ' \
                           "evidence_ref=google-approval-1 observed_at=#{observed} expires_at=none",
                           *state_lines('qualification_pending', approval: approval)])
      expect(record('approval')).to eq(gmail_identity.merge('status' => 'approved', 'evidence_ref' => 'google-approval-1',
                                                            'observed_at' => observed))
      expect(InstallationConfig.find_by(name: 'TOYBACO_CONNECTION_RELEASES')).to have_attributes(locked: true)
      expect(InstallationConfig.editable.where(name: 'TOYBACO_CONNECTION_RELEASES')).to be_empty
      expect_no_secrets(lines)
    end

    it 'qualification は期限付きで記録し、判定が connection_check_pending へ進む。ほかの provider・環境の記録は保つ' do
      production = { 'microsoft_graph' => { 'disabled' => true } }
      InstallationConfig.create!(name: 'TOYBACO_CONNECTION_RELEASES', value: { 'production' => production }, locked: true)
      run!('connection_release_approve', 'gmail_rest', 'approval', 'google-approval-1', observed, 'none')
      lines = run!('connection_release_approve', 'gmail_rest', 'qualification', 'casa-tier2-1', observed, expires)
      expect(lines.second).to end_with('available=false reason=connection_check_pending')
      expect(lines.fourth).to end_with("kind=qualification recorded=true status=approved evidence_ref=casa-tier2-1 observed_at=#{observed} " \
                                       "expires_at=#{expires} identity=match")
      expect(record('qualification')).to eq(gmail_identity.merge('status' => 'approved', 'evidence_ref' => 'casa-tier2-1',
                                                                 'observed_at' => observed, 'expires_at' => expires))
      expect(releases['production']).to eq(production)
    end

    it '読み直しの判定が進まない記録(approval の前の qualification・停止中)は abort して rollback し、failed を残す' do
      qualification = %W[gmail_rest qualification casa-1 #{observed} #{expires}]
      expect(expect_refusal('connection_release_approve', *qualification)).to eq(
        'gmail_rest の読み直しの判定が connection_check_pending か available になりません(reason=review_pending)。保存しません。' \
        'TOYBACO_CONNECTION_RELEASES と記録の順(approval → qualification → smoke)を確認してください。'
      )
      run!('connection_release_disable', 'gmail_rest', 'on')
      expect(expect_refusal('connection_release_approve', 'gmail_rest', 'approval', 'approval-1', observed, 'none')).to include('(reason=disabled)')
      expect(record('approval')).to be_nil
      expect(new_rows.where(action: 'rake.toybaco:connection_release_approve').pluck(:result)).to eq(%w[started failed] * 2)
    end

    it '読み手の判定(public_decision)が書いた記録を反映しなければ abort して rollback する' do
      allow(Toybaco::Connections::Gmail).to receive(:public_decision).and_return({ 'available' => false, 'reason' => 'review_pending' })
      message = expect_refusal('connection_release_approve', 'gmail_rest', 'approval', 'approval-1', observed, 'none')
      expect(message).to start_with('gmail_rest の読み直しの判定が qualification_pending / connection_check_pending か available になりません')
      expect(releases).to be_nil
    end

    it '失効(revoked)の記録は上書きせずに abort し、何も書かない(approval の失効中は qualification も判定が進まず保存しない)' do
      revoked = gmail_identity.merge('status' => 'revoked', 'evidence_ref' => 'google-revoked-1', 'observed_at' => observed)
      InstallationConfig.create!(name: 'TOYBACO_CONNECTION_RELEASES', value: { 'staging' => { 'gmail_rest' => { 'approval' => revoked } } },
                                 locked: true)
      expect(expect_refusal('connection_release_approve', 'gmail_rest', 'approval', 'approval-2', observed, 'none')).to eq(
        'gmail_rest の approval は失効(revoked)として記録されているため上書きしません。失効の扱いは DB の記録を確かめてから別に行ってください。'
      )
      expect(expect_refusal('connection_release_approve', 'gmail_rest', 'qualification', 'casa-1', observed, expires)).to include('(reason=revoked)')
      expect(record('approval')).to eq(revoked)
      expect(record('qualification')).to be_nil
      expect(new_rows.where(action: 'rake.toybaco:connection_release_approve').pluck(:result)).to eq(%w[started failed] * 2)
    end

    it '上書きの前の状態を previous に出し、失効した qualification も上書きしない' do
      InstallationConfig.create!(name: 'TOYBACO_CONNECTION_RELEASES', locked: true, value: {
                                   'staging' => { 'gmail_rest' => { 'qualification' => { 'status' => 'revoked' } },
                                                  'microsoft_graph' => { 'approval' => { 'status' => 'submitted' } } }
                                 })
      expect(run!('connection_release_approve', 'gmail_rest', 'approval', 'approval-1', observed, 'none').first).to include('previous=absent')
      expect(run!('connection_release_approve', 'gmail_rest', 'approval', 'approval-2', observed, 'none').first).to include('previous=approved')
      expect(run!('connection_release_approve', 'microsoft_graph', 'approval', 'approval-3', observed, 'none').first)
        .to include('previous=non_conforming')
      expect(expect_refusal('connection_release_approve', 'gmail_rest', 'qualification', 'casa-1', observed, expires)).to start_with(
        'gmail_rest の qualification は失効(revoked)として記録されているため上書きしません。'
      )
      expect(record('qualification')).to eq('status' => 'revoked')
    end

    it '保存した行が locked でなければ(SuperAdmin の画面から編集できる状態なら)abort して rollback する' do
      allow(InstallationConfig).to receive(:find_by).and_wrap_original do |original, *args, **options|
        original.call(*args, **options).tap { |row| row.locked = false if row&.name == 'TOYBACO_CONNECTION_RELEASES' }
      end
      expect(expect_refusal('connection_release_approve', 'gmail_rest', 'approval', 'approval-1', observed, 'none')).to start_with(
        'TOYBACO_CONNECTION_RELEASES の読み直しが書いた値と一致しないか、画面から隠れていない(locked でない)ため保存しません。'
      )
      expect(InstallationConfig.unscoped.where(name: 'TOYBACO_CONNECTION_RELEASES')).to be_empty
    end

    it 'kind・証跡 ID・時刻・期限・余分な引数の誤りは abort し、何も保存しない' do
      valid = ['gmail_rest', 'approval', 'approval-1', observed, 'none']
      invalid = { 1 => ['revoked', 'Approval', 'smoke', nil], 2 => ['', 'a b', 'x' * 81, 'ref,1', "ref\n1", nil],
                  3 => ['2026-09-29 09:00:00Z', '2026-09-29T09:00:00+09:00', '2026-09-29T09:00Z', '2026-02-30T00:00:00Z',
                        '2026-09-30T24:00:00Z', '2026-09-30T03:00:01Z', 'none', nil],
                  4 => ['2026-09-30T03:00:00Z', '2020-01-01T00:00:00Z', 'None', '2027-13-01T00:00:00Z', nil] }
      invalid.each do |index, values|
        values.each { |value| expect_refusal('connection_release_approve', *valid.dup.tap { |args| args[index] = value }) }
      end
      expect(expect_refusal('connection_release_approve', 'gmail_rest', 'qualification', 'casa-1', observed, 'none')).to eq(
        'qualification(セキュリティ評価)は期限の記録が必要です。expires_at を YYYY-MM-DDTHH:MM:SSZ で指定してください。'
      )
      expect(expect_refusal('connection_release_approve', *valid, 'x')).to eq(
        '引数は provider,kind,evidence_ref,observed_at,expires_at の 5 つだけを指定してください。'
      )
      expect(new_rows.where(result: 'failed').count).to eq(invalid.values.sum(&:size) + 2)
    end

    it 'client ID が未設定・環境が staging / production 以外なら abort し、何も保存しない' do
      InstallationConfig.find_by(name: 'TOYBACO_GMAIL_CLIENT_ID').update!(value: '')
      GlobalConfig.clear_cache
      expect(expect_refusal('connection_release_approve', 'gmail_rest', 'approval', 'approval-1', observed, 'none')).to eq(
        'gmail_rest の client ID(TOYBACO_GMAIL_CLIENT_ID)が未設定のため記録しません。'
      )
      with_modified_env(TOYBACO_DEPLOYMENT_ENVIRONMENT: nil) do
        expect(expect_refusal('connection_release_approve', 'microsoft_graph', 'approval', 'approval-1', observed, 'none')).to eq(
          'TOYBACO_DEPLOYMENT_ENVIRONMENT が staging / production ではないため記録しません。'
        )
      end
    end

    it '監査行に started と ok が残り、params_digest は 5 つの引数の digest と一致する' do
      run!('connection_release_approve', 'gmail_rest', 'approval', 'approval-1', observed, 'none')
      digest = Toybaco::Ops::Audit.params_digest({ 'provider' => 'gmail_rest', 'kind' => 'approval', 'evidence_ref' => 'approval-1',
                                                   'observed_at' => observed, 'expires_at' => 'none' })
      expect(new_rows.pluck(:actor_kind, :action, :result, :source, :params_digest)).to eq(
        [['rake', 'rake.toybaco:connection_release_approve', 'started', 'rake:unspecified', digest],
         ['rake', 'rake.toybaco:connection_release_approve', 'ok', 'rake:unspecified', digest]]
      )
    end
  end

  describe 'toybaco:connection_release_smoke' do
    let(:account) { create(:account) }

    it '列挙した項目だけを true で記録し、全項目がそろうまで connection_check_pending のまま接続を開かない' do
      run!('connection_release_approve', 'gmail_rest', 'approval', 'approval-1', observed, 'none')
      run!('connection_release_approve', 'gmail_rest', 'qualification', 'casa-1', observed, expires)
      lines = run!('connection_release_smoke', 'gmail_rest', 'smoke-1', observed, 'authorization.callback.receive.reply.disconnect')
      expect(lines.first(2)).to eq(['TOYBACO_CONNECTION_RELEASE_SMOKE provider=gmail_rest environment=staging evidence_ref=smoke-1 ' \
                                    "observed_at=#{observed} checks=5/6",
                                    'TOYBACO_CONNECTION_RELEASE provider=gmail_rest environment=staging available=false ' \
                                    'reason=connection_check_pending'])
      expect(record('smoke')).to eq(gmail_identity.merge(
                                      'environment' => 'staging', 'implementation_revision' => 'gmail-rest-v1', 'evidence_ref' => 'smoke-1',
                                      'observed_at' => observed,
                                      'checks' => { 'authorization' => true, 'callback' => true, 'receive' => true, 'reply' => true,
                                                    'disconnect' => true, 'tenant_isolation' => false }
                                    ))
      expect(Toybaco::Connections::Gmail.allowed?(account)).to be(false)
      lines = run!('connection_release_smoke', 'gmail_rest', 'smoke-2', observed, all_checks)
      expect(lines.second).to eq('TOYBACO_CONNECTION_RELEASE provider=gmail_rest environment=staging available=true reason=none')
      expect(Toybaco::Connections::Gmail.allowed?(account)).to be(true)
      expect_no_secrets(lines)
    end

    it '承認・評価の記録より前の実測は、読み直しの判定が進まないため abort して rollback する' do
      expect(expect_refusal('connection_release_smoke', 'gmail_rest', 'smoke-1', observed, all_checks)).to eq(
        'gmail_rest の読み直しの判定が available になりません(reason=review_pending)。保存しません。' \
        'TOYBACO_CONNECTION_RELEASES と記録の順(approval → qualification → smoke)を確認してください。'
      )
      expect(releases).to be_nil
    end

    it '未知の項目・重複・正規の順でない並び・空の項目・空の一覧は abort し、何も保存しない' do
      run!('connection_release_approve', 'gmail_rest', 'approval', 'approval-1', observed, 'none')
      run!('connection_release_approve', 'gmail_rest', 'qualification', 'casa-1', observed, expires)
      message = 'checks は authorization / callback / receive / reply / disconnect / tenant_isolation のうち実測で合格した項目だけを、' \
                'この順に各 1 回まで . で区切って指定してください。'
      ['authorization.delete', 'authorization.authorization', 'authorization..reply', 'authorization.', '', 'Authorization', nil,
       "#{all_checks}.scope", 'reply.authorization', 'callback.authorization.receive', 'tenant_isolation.disconnect'].each do |checks|
        expect(expect_refusal('connection_release_smoke', 'gmail_rest', 'smoke-1', observed, checks)).to eq(message)
      end
      expect(record('smoke')).to be_nil
    end
  end

  describe 'toybaco:connection_release_disable' do
    it 'on で読み手の判定を disabled にして審査用店舗も止め、off で元の判定に戻す' do
      open!
      account = create(:account)
      InstallationConfig.create!(name: 'TOYBACO_CONNECTION_REVIEW_ACCOUNTS', value: { 'staging' => { 'gmail_rest' => [account.id] } })
      lines = run!('connection_release_disable', 'gmail_rest', 'on')
      expect(lines.first(2)).to eq(['TOYBACO_CONNECTION_RELEASE_DISABLE provider=gmail_rest environment=staging disabled=true previous=unset',
                                    'TOYBACO_CONNECTION_RELEASE provider=gmail_rest environment=staging available=false reason=disabled'])
      expect(lines.last).to eq('TOYBACO_CONNECTION_RELEASE_RECORD provider=gmail_rest kind=disabled value=true')
      expect(Toybaco::Connections::Gmail.allowed?(account)).to be(false)
      lines = run!('connection_release_disable', 'gmail_rest', 'off')
      expect(lines.first(2)).to eq(['TOYBACO_CONNECTION_RELEASE_DISABLE provider=gmail_rest environment=staging disabled=false previous=true',
                                    'TOYBACO_CONNECTION_RELEASE provider=gmail_rest environment=staging available=true reason=none'])
      expect(record('disabled')).to be(false)
    end

    it 'client ID が未設定で判定が記録より前に止まっていても停止は記録し、on / off 以外と余分な引数は abort する' do
      InstallationConfig.find_by(name: 'TOYBACO_MICROSOFT_CLIENT_ID').update!(value: '')
      GlobalConfig.clear_cache
      lines = run!('connection_release_disable', 'microsoft_graph', 'on')
      expect(lines.second).to end_with('available=false reason=application_unconfigured')
      expect(record('disabled', 'microsoft_graph')).to be(true)
      ['ON', 'true', '1', '', nil].each { |state| expect_refusal('connection_release_disable', 'gmail_rest', state) }
      expect(expect_refusal('connection_release_disable', 'gmail_rest', 'on', 'off')).to eq('引数は provider,on|off の 2 つだけを指定してください。')
      expect(record('disabled')).to be_nil
    end
  end

  describe 'toybaco:connection_release_clear' do
    let(:others) do
      { 'staging' => { 'microsoft_graph' => { 'disabled' => true } }, 'production' => { 'gmail_rest' => { 'disabled' => false } } }
    end

    it 'staging では provider の記録だけを消し、ほかの provider と production の記録は保つ' do
      InstallationConfig.create!(name: 'TOYBACO_CONNECTION_RELEASES', value: others, locked: true)
      open!
      lines = run!('connection_release_clear', 'gmail_rest')
      expect(lines).to eq(['TOYBACO_CONNECTION_RELEASE_CLEAR provider=gmail_rest environment=staging previous=present',
                           *state_lines('review_pending')])
      expect(releases).to eq(others)
      expect(run!('connection_release_clear', 'gmail_rest').first).to end_with('previous=absent')
    end

    it 'production と環境が不明なときは abort し、記録を消さない' do
      InstallationConfig.create!(name: 'TOYBACO_CONNECTION_RELEASES', value: others, locked: true)
      message = 'clear は staging 専用です。production の記録は消さず、停止は disable で行ってください。'
      [{ TOYBACO_DEPLOYMENT_ENVIRONMENT: 'production' }, { TOYBACO_DEPLOYMENT_ENVIRONMENT: nil },
       { TOYBACO_DEPLOYMENT_ENVIRONMENT: 'Staging' }].each do |env|
        with_modified_env(env) do
          expect(expect_refusal('connection_release_clear', 'gmail_rest')).to eq(message)
        end
      end
      expect(releases).to eq(others)
      expect(new_rows.pluck(:result)).to eq(%w[started failed] * 3)
    end
  end

  describe 'toybaco:connection_handoff_mail' do
    let(:callback) { 'https://app.staging.toybaco.jp/toybaco/connections/help/oauth/gmail/callback' }
    let(:gateway) { Toybaco::Connections::Handoff::MailGateway.new('gmail') }

    def handoff_value
      InstallationConfig.find_by(name: 'TOYBACO_CONNECTION_HANDOFF_MAIL')&.value
    end

    it 'keep は MailGateway の登録一致判定が通る登録を書き、ほかの環境の登録と依頼メールの有効・無効は変えない' do
      production = { 'microsoft' => { 'application_id' => 'x', 'callback_url' => 'y', 'implementation_revision' => 'z' } }
      InstallationConfig.create!(name: 'TOYBACO_CONNECTION_HANDOFF_MAIL', value: { 'production' => production }, locked: true)
      lines = run!('connection_handoff_mail', 'gmail', 'keep')
      expect(lines).to eq(["TOYBACO_CONNECTION_HANDOFF_MAIL provider=gmail environment=staging registered=true callback_url=#{callback} " \
                           'implementation_revision=gmail-rest-v1 enabled=unset'])
      expect(handoff_value).to eq('production' => production, 'staging' => {
                                    'gmail' => { 'application_id' => 'fixture-gmail-client-id', 'callback_url' => callback,
                                                 'implementation_revision' => 'gmail-rest-v1' }
                                  })
      expect(gateway.send(:registered_callback?)).to be(true)
      expect(InstallationConfig.find_by(name: 'TOYBACO_CONNECTION_HANDOFF_ENABLED')).to be_nil
      expect_no_secrets(lines)
    end

    it 'enable は依頼メールを JSON の boolean true で有効にし、cache に古い無効が残っていても読み手が有効と読む' do
      InstallationConfig.create!(name: 'TOYBACO_CONNECTION_HANDOFF_ENABLED', value: false, locked: false)
      expect(Toybaco::Connections::Handoff::Access.enabled?).to be(false)
      lines = run!('connection_handoff_mail', 'microsoft', 'enable')
      expect(lines.first).to end_with('/toybaco/connections/help/oauth/microsoft/callback implementation_revision=microsoft-graph-v1 enabled=true')
      expect(InstallationConfig.find_by(name: 'TOYBACO_CONNECTION_HANDOFF_ENABLED')).to have_attributes(value: true, locked: true)
      expect(Toybaco::Connections::Handoff::Access.enabled?).to be(true)
      expect(Toybaco::Connections::Handoff::MailGateway.new('microsoft').send(:registered_callback?)).to be(true)
    end

    it '有効化を読み手(cache を経由する Handoff::Access.enabled?)が有効と読めなければ abort し、登録も有効化も commit しない' do
      allow(Toybaco::Connections::Handoff::Access).to receive(:enabled?).and_return(false)
      expect(expect_refusal('connection_handoff_mail', 'gmail', 'enable')).to eq(
        'TOYBACO_CONNECTION_HANDOFF_ENABLED を有効にしても、読み手(GlobalConfigService)がそう読めないため保存しません。' \
        'TOYBACO_CONNECTION_HANDOFF_ENABLED の行と cache を確認してください。'
      )
      expect([handoff_value, InstallationConfig.find_by(name: 'TOYBACO_CONNECTION_HANDOFF_ENABLED')]).to eq([nil, nil])
    end

    it 'disable は登録を変えずに依頼の有効化だけを boolean false に戻し、読み手が無効と読めなければ戻さない' do
      run!('connection_handoff_mail', 'gmail', 'enable')
      registered = handoff_value
      allow(Toybaco::Connections::Handoff::Access).to receive(:enabled?).and_return(true)
      expect(expect_refusal('connection_handoff_mail', 'microsoft', 'disable')).to start_with('TOYBACO_CONNECTION_HANDOFF_ENABLED を無効にしても')
      allow(Toybaco::Connections::Handoff::Access).to receive(:enabled?).and_call_original
      expect(run!('connection_handoff_mail', 'microsoft', 'disable')).to eq(
        ['TOYBACO_CONNECTION_HANDOFF_MAIL provider=microsoft environment=staging action=disable enabled=false']
      )
      expect(InstallationConfig.find_by(name: 'TOYBACO_CONNECTION_HANDOFF_ENABLED')).to have_attributes(value: false, locked: true)
      expect([Toybaco::Connections::Handoff::Access.enabled?, handoff_value]).to eq([false, registered])
    end

    it '登録の一致判定が読み直しで偽なら abort して、登録も有効化も rollback する' do
      allow(Toybaco::Connections::Handoff::MailGateway).to receive(:new).and_wrap_original do |original, provider|
        original.call(provider).tap { |built| allow(built).to receive(:registered_callback?).and_return(false) }
      end
      expect(expect_refusal('connection_handoff_mail', 'gmail', 'enable')).to eq(
        'gmail の担当者依頼の登録を読み直せないため保存しません。TOYBACO_CONNECTION_HANDOFF_MAIL を確認してください。'
      )
      expect([handoff_value, InstallationConfig.find_by(name: 'TOYBACO_CONNECTION_HANDOFF_ENABLED')]).to eq([nil, nil])
    end

    it 'provider・2 つ目の引数・FRONTEND_URL の origin・client ID の誤りは abort し、何も保存しない' do
      ['gmail_rest', 'Gmail', nil].each { |provider| expect_refusal('connection_handoff_mail', provider, 'keep') }
      ['Enable', 'Disable', 'on', nil].each { |mode| expect_refusal('connection_handoff_mail', 'gmail', mode) }
      with_modified_env(FRONTEND_URL: 'https://untrusted.example.test') do
        expect(expect_refusal('connection_handoff_mail', 'gmail', 'keep')).to eq(
          'FRONTEND_URL が https://app.toybaco.jp / https://app.staging.toybaco.jp ではないため登録しません。'
        )
      end
      with_modified_env(TOYBACO_DEPLOYMENT_ENVIRONMENT: 'production') do
        expect(expect_refusal('connection_handoff_mail', 'gmail', 'keep')).to eq(
          'FRONTEND_URL の origin が production の https://app.toybaco.jp と一致しないため登録しません。'
        )
      end
      InstallationConfig.find_by(name: 'TOYBACO_GMAIL_CLIENT_ID').update!(value: '')
      GlobalConfig.clear_cache
      expect(expect_refusal('connection_handoff_mail', 'gmail', 'keep')).to eq('gmail の client ID が未設定のため担当者依頼を登録しません。')
      expect(new_rows.where(result: 'failed').count).to eq(10)
    end
  end

  # B5: 記録は全環境・全 provider で 1 行なので、行ロックが無いと、先に行を読んだ実行が後から保存して、その間に別の実行が保存した
  # 記録(緊急停止を含む)を古い値で上書きする。ops-rake の concurrency の外(直接の rake・run-task)で重なる場合を、別の DB 接続の
  # thread で実際に交差させて確かめる。transactional test の中では別の接続から見えないため、この group だけ確定した行を使って後で消す。
  describe '同時に動いた運営 rake' do
    self.use_transactional_tests = false

    after do
      InstallationConfig.where(name: %w[TOYBACO_CONNECTION_RELEASES TOYBACO_GMAIL_CLIENT_ID TOYBACO_GMAIL_CLIENT_SECRET
                                        TOYBACO_MICROSOFT_CLIENT_ID TOYBACO_MICROSOFT_CLIENT_SECRET]).delete_all
    end

    # first(この thread)が記録の行を読んだ直後に、second を別の DB 接続の thread で走らせる。second が行ロックを待つか終わるまで
    # 待ってから first を進め、最後に second の終わりを待つ。second の失敗(abort を含む)はこの例の失敗にする。
    def interleave(first, second)
      main = Thread.current
      second_thread = nil
      allow(described_class::Records).to receive(:locked_row).and_wrap_original do |original, name|
        row = original.call(name)
        second_thread ||= start_second(second, Queue.new) if Thread.current == main
        row
      end
      capture(:stdout) do
        run_task(*first)
        raise 'second rake did not finish' unless second_thread&.join(30)
      end
      raise second_thread[:failure] if second_thread[:failure]
    end

    def start_second(task, pid)
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          pid << connection.raw_connection.backend_pid
          run_task(*task)
        end
      rescue SystemExit, StandardError => e
        Thread.current[:failure] = RuntimeError.new("second rake failed: #{e.class} #{e.message}")
      end
      wait_for_lock_or_end(pid.pop, thread)
      thread
    end

    def wait_for_lock_or_end(pid, thread)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      until thread.join(0.05)
        waiting = ActiveRecord::Base.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}")
        return if waiting == 'Lock'
        raise 'second rake neither waited for the row lock nor finished' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      end
    end

    it '別 provider の記録の更新と disable,on が交差しても、停止と両方の記録が残る' do
      open!
      interleave(%W[connection_release_approve microsoft_graph approval approval-9 #{observed} none],
                 %w[connection_release_disable gmail_rest on])
      expect(releases.dig('staging', 'gmail_rest', 'disabled')).to be(true)
      expect(releases.dig('staging', 'gmail_rest', 'smoke', 'checks', 'tenant_isolation')).to be(true)
      expect(releases.dig('staging', 'microsoft_graph', 'approval', 'evidence_ref')).to eq('approval-9')
      expect(Toybaco::Connections::Gmail.public_decision['reason']).to eq('disabled')
    end

    it '記録の行がまだ無い時に同時に作られても、先に作った方の記録を上書きしない' do
      interleave(%W[connection_release_approve microsoft_graph approval approval-9 #{observed} none],
                 %w[connection_release_disable gmail_rest on])
      expect(InstallationConfig.where(name: 'TOYBACO_CONNECTION_RELEASES').count).to eq(1)
      expect(releases['staging']).to eq('microsoft_graph' => microsoft_approval, 'gmail_rest' => { 'disabled' => true })
    end
  end
end
