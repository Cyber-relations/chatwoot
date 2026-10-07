# frozen_string_literal: true

require 'rails_helper'
require 'active_support/testing/stream'

Rails.application.load_tasks unless Rake::Task.task_defined?('toybaco:e2e_captcha_test_keys')

# staging の E2E(無料登録の hCaptcha)用の運営 rake(toybaco:e2e_captcha_test_keys[on|off|show])。staging 以外では引数を読む前に abort する
# こと、mode の検査、on で 2 行が hCaptcha 公式の公開 test 鍵になり読み手(GlobalConfigService.load と ChatwootCaptcha)が読めること、実鍵
# (foreign)が行か同じ名前の環境変数に 1 つでもあれば on / off が何も書かずに abort すること、off で 2 行が空文字になる(行は残る)こと、
# show の分類、出力と abort の文に鍵の値(test 定数を含む)が出ないこと、監査行を確かめる。1 つの transaction(外側の transaction の中でも
# savepoint)・例外のときに cache を消さないこと・同時実行の直列化(advisory lock)は、commit と rollback を別の接続から見るため、
# transactional test を外した group で確定した行を使って確かめる(connection_release_ops_spec と同じ)。
# GlobalConfig の値は Redis に残り DB の transaction では戻らないため、前後で消す(free_registration_captcha_spec と同じ)。鍵は
# installation_configs の行で与え、環境変数は例ごとに明示する(既定は未設定)。
# 置き場所は他の overlay spec(spec/lib/toybaco/*_spec.rb)と揃え、rspec manifest の名簿で固定している。
RSpec.describe Toybaco::Ops::E2eCaptcha do # rubocop:disable RSpec/SpecFilePathFormat
  include ActiveSupport::Testing::Stream

  let!(:baseline) { Toybaco::OperatorAction.maximum(:id).to_i }
  let(:site_key) { described_class::TEST_SITE_KEY }
  let(:secret) { described_class::TEST_SECRET }
  # staging に実鍵が入っている状態の代わり(空でも test 定数でもない値)。出力に出ないことを確かめるため test 定数と別の形にする。
  let(:real_site_key) { 'b144cab8-0000-4000-8000-site-key-fixture' }
  let(:real_secret) { 'ES_server-key-fixture-0123456789abcdef' }
  let(:names) { %w[HCAPTCHA_SITE_KEY HCAPTCHA_SERVER_KEY] }
  let(:writes) { %w[on off] }
  let(:on_line) { 'TOYBACO_E2E_CAPTCHA mode=on site_key=test server_key=test' }
  let(:off_line) { 'TOYBACO_E2E_CAPTCHA mode=off site_key=empty server_key=empty' }
  let(:staging_only) { 'e2e_captcha_test_keys は staging 専用です。production と環境が不明なときは実行しません。' }
  let(:mode_invalid) { 'TOYBACO_E2E_CAPTCHA_ABORT reason=mode_invalid' }
  let(:foreign_keys) { 'TOYBACO_E2E_CAPTCHA_ABORT reason=foreign_keys' }

  around do |example|
    with_modified_env(TOYBACO_DEPLOYMENT_ENVIRONMENT: 'staging', TOYBACO_OPS_ACTOR: nil, TOYBACO_OPS_SOURCE: nil,
                      HCAPTCHA_SITE_KEY: nil, HCAPTCHA_SERVER_KEY: nil) { example.run }
  end

  before { GlobalConfig.clear_cache }

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

  def run_task(*values)
    task = Rake::Task['toybaco:e2e_captcha_test_keys']
    task.execute(Rake::TaskArguments.new(task.arg_names, values))
  end

  # 成功するはずの呼び出し。想定外の abort(SystemExit)は RSpec の実行全体を止めるため、この例の失敗に置き換える。
  def run!(*values)
    capture(:stdout) { run_task(*values) }.lines(chomp: true)
  rescue SystemExit
    raise RSpec::Expectations::ExpectationNotMetError, "toybaco:e2e_captcha_test_keys[#{values.join(',')}] が abort しました"
  end

  # abort することを確かめ、abort の文(標準エラー)を返す。標準出力には何も出さない。
  def refusal(*values)
    message = nil
    printed = capture(:stdout) { message = capture(:stderr) { expect { run_task(*values) }.to raise_error(SystemExit) } }
    expect(printed).to eq('')
    message.chomp
  end

  # 2 行の値を入れる。上流の既定値の読み込みで値の無い行が先にあることがあるため、行があれば値を入れ、無ければ作る。nil は値の無い行。
  def store(site, server)
    { 'HCAPTCHA_SITE_KEY' => site, 'HCAPTCHA_SERVER_KEY' => server }.each do |name, value|
      InstallationConfig.find_or_initialize_by(name: name).update!(value: value, locked: false)
    end
    GlobalConfig.clear_cache
  end

  def values
    names.map { |name| InstallationConfig.find_by(name: name)&.value }
  end

  def snapshot
    InstallationConfig.where(name: names).reorder(:name).map { |row| row.attributes.slice('name', 'serialized_value', 'locked', 'updated_at') }
  end

  # 別の DB 接続で読んだ 2 行(名前・serialized_value・locked、名前の順)。確定した値だけが見える。
  def committed_rows
    connection = ActiveRecord::Base.connection_db_config.new_connection
    connection.select_rows('SELECT name, serialized_value::text, locked FROM installation_configs ' \
                           "WHERE name IN ('HCAPTCHA_SITE_KEY', 'HCAPTCHA_SERVER_KEY') ORDER BY name")
  ensure
    connection&.disconnect!
  end

  def readers
    names.map { |name| GlobalConfigService.load(name, '') }
  end

  # 出力・abort の文のどこにも鍵の値(test 定数と実鍵)が無いこと。
  def expect_no_key_values(text)
    expect(text).not_to include(site_key, secret, real_site_key, real_secret)
  end

  describe 'toybaco:e2e_captcha_test_keys' do
    it 'staging 以外(production・環境が不明・大文字違い)では、引数を読む前に abort して何も書かない' do
      store(nil, nil)
      saved = snapshot
      modes = %w[on off show invalid]
      [{ TOYBACO_DEPLOYMENT_ENVIRONMENT: 'production' }, { TOYBACO_DEPLOYMENT_ENVIRONMENT: nil },
       { TOYBACO_DEPLOYMENT_ENVIRONMENT: 'Staging' }].each do |env|
        with_modified_env(env) do
          modes.each { |mode| expect(refusal(mode)).to eq(staging_only) }
        end
      end
      expect(snapshot).to eq(saved)
      expect(new_rows.pluck(:result)).to eq(%w[started failed] * 12)
    end

    it 'mode が on / off / show の文字列でないか余分な引数があれば、入力を出さずに abort して何も書かない' do
      store(nil, nil)
      saved = snapshot
      invalid = [nil, '', 'ON', 'On', 'enable', 'true', 'onx', ' on', "on\n", 'show ', :on]
      invalid.each { |value| expect(refusal(value)).to eq(mode_invalid) }
      expect(refusal('on', 'x')).to eq(mode_invalid)
      expect(refusal).to eq(mode_invalid)
      expect(snapshot).to eq(saved)
      expect(new_rows.pluck(:result)).to eq(%w[started failed] * (invalid.size + 2))
    end

    it 'on: 値の無い行(上流の既定)を公開 test 鍵にし、読み手(GlobalConfigService.load と ChatwootCaptcha)が読める。分類だけを出す' do
      store(nil, nil)
      # 読み手の cache に値の無い状態を残しておき、on の後に消えて新しい値を読むことも確かめる。
      expect(readers).to eq([nil, nil])
      lines = run!('on')
      expect(lines).to eq([on_line])
      expect([values, InstallationConfig.where(name: names).pluck(:locked)]).to eq([[site_key, secret], [false, false]])
      expect(readers).to eq([site_key, secret])
      # 無料登録の検査(ChatwootCaptcha)は test の server key で hCaptcha に問い合わせる(外部には出さない)。
      stub_request(:post, 'https://hcaptcha.com/siteverify')
        .with(body: { response: 'client-token-fixture', secret: secret })
        .to_return(status: 200, body: { success: true }.to_json, headers: { 'Content-Type' => 'application/json' })
      expect(ChatwootCaptcha.new('client-token-fixture').valid?).to be(true)
      expect_no_key_values(lines.join("\n"))
    end

    it 'on: 行が無ければ作り、片方だけが test 鍵(もう片方が空)でも両方を test 鍵にし、再実行しても同じ結果になる' do
      InstallationConfig.where(name: names).delete_all
      expect(run!('on')).to eq([on_line])
      expect([values, InstallationConfig.where(name: names).pluck(:locked)]).to eq([[site_key, secret], [false, false]])
      store(site_key, '')
      expect(run!('on')).to eq([on_line])
      expect(run!('on')).to eq([on_line])
      expect([values, InstallationConfig.where(name: names).count]).to eq([[site_key, secret], 2])
    end

    it 'foreign: 実鍵が 1 つでもあれば on / off は何も書かずに abort し、値を変えない(空白だけ・型違い・大文字違い・もう一方の行の test 定数も同じ扱い)' do
      cases = [[real_site_key, real_secret], [real_site_key, nil], [nil, real_secret], [site_key, real_secret], [real_site_key, secret],
               ['', real_secret], ['  ', nil], [true, nil], [site_key.upcase, nil], [nil, secret.upcase], [secret, site_key]]
      cases.each do |site, server|
        store(site, server)
        saved = snapshot
        writes.each { |mode| expect(refusal(mode)).to eq(foreign_keys) }
        expect([snapshot, values]).to eq([saved, [site, server]])
      end
      expect(new_rows.pluck(:result)).to eq(%w[started failed] * (cases.size * 2))
    end

    it 'foreign: site 行だけに実鍵があり server 行が無いとき、on / off は abort し、行の数と serialized_value を変えない' do
      InstallationConfig.where(name: names).delete_all
      InstallationConfig.create!(name: 'HCAPTCHA_SITE_KEY', value: real_site_key, locked: false)
      saved = snapshot
      writes.each { |mode| expect(refusal(mode)).to eq(foreign_keys) }
      expect([InstallationConfig.where(name: names).count, snapshot]).to eq([1, saved])
    end

    it 'foreign: 環境変数だけにある実鍵は、行が無くても値の無い行でも on / off が何も書かずに abort し、show は foreign を出す' do
      { { HCAPTCHA_SITE_KEY: real_site_key } => 'site_key=foreign server_key=empty',
        { HCAPTCHA_SERVER_KEY: real_secret } => 'site_key=empty server_key=foreign',
        { HCAPTCHA_SITE_KEY: site_key.upcase, HCAPTCHA_SERVER_KEY: secret.upcase } => 'site_key=foreign server_key=foreign',
        { HCAPTCHA_SITE_KEY: secret, HCAPTCHA_SERVER_KEY: '  ' } => 'site_key=foreign server_key=foreign' }.each do |env, expected|
        InstallationConfig.where(name: names).delete_all
        with_modified_env(env) do
          writes.each { |mode| expect(refusal(mode)).to eq(foreign_keys) }
          expect(InstallationConfig.where(name: names).count).to eq(0)
          store(nil, nil)
          saved = snapshot
          writes.each { |mode| expect(refusal(mode)).to eq(foreign_keys) }
          expect([snapshot, run!('show')]).to eq([saved, ["TOYBACO_E2E_CAPTCHA mode=show #{expected}"]])
        end
      end
    end

    it '環境変数が空(未設定・空文字)か test 定数なら、行が無くても従来どおり on で書き、off で空にする' do
      [{}, { HCAPTCHA_SITE_KEY: '', HCAPTCHA_SERVER_KEY: '' }, { HCAPTCHA_SITE_KEY: site_key, HCAPTCHA_SERVER_KEY: secret }].each do |env|
        InstallationConfig.where(name: names).delete_all
        with_modified_env(env) do
          expect(run!('on')).to eq([on_line])
          expect(values).to eq([site_key, secret])
          expect(run!('off')).to eq([off_line])
          expect(values).to eq(['', ''])
        end
      end
    end

    it 'off: test 鍵を空文字にし(行は残す)、読み手は鍵が無いものとして扱う。再実行しても同じ結果になる' do
      store(site_key, secret)
      # 読み手の cache に test 鍵を残しておき、off の後に消えることも確かめる。
      expect(readers).to eq([site_key, secret])
      lines = run!('off')
      expect(lines).to eq([off_line])
      expect([values, InstallationConfig.where(name: names).pluck(:locked)]).to eq([['', ''], [false, false]])
      # server key が空なら無料登録は CAPTCHA を検査しない(上流の ChatwootCaptcha と同じ。hCaptcha には問い合わせない)。
      expect([readers, ChatwootCaptcha.new('client-token-fixture').valid?]).to eq([[nil, nil], true])
      expect(run!('off')).to eq([off_line])
      expect_no_key_values(lines.join("\n"))
    end

    it 'off: 値の無い行・片方だけの test 鍵・行の無い状態も空文字の 2 行にする' do
      [[nil, nil], [site_key, nil], ['', secret]].each do |site, server|
        store(site, server)
        expect(run!('off')).to eq([off_line])
        expect(values).to eq(['', ''])
      end
      InstallationConfig.where(name: names).delete_all
      expect(run!('off')).to eq([off_line])
      expect([values, InstallationConfig.where(name: names).pluck(:locked)]).to eq([['', ''], [false, false]])
    end

    it 'show: 2 行の分類だけを出し、行を書き換えず、行が無くても作らない' do
      { [nil, nil] => 'site_key=empty server_key=empty', [site_key, secret] => 'site_key=test server_key=test',
        [real_site_key, ''] => 'site_key=foreign server_key=empty', [site_key, real_secret] => 'site_key=test server_key=foreign',
        [secret, site_key] => 'site_key=foreign server_key=foreign' }.each do |(site, server), expected|
        store(site, server)
        saved = snapshot
        lines = run!('show')
        expect(lines).to eq(["TOYBACO_E2E_CAPTCHA mode=show #{expected}"])
        expect(snapshot).to eq(saved)
        expect_no_key_values(lines.join("\n"))
      end
      InstallationConfig.where(name: names).delete_all
      expect(run!('show')).to eq(['TOYBACO_E2E_CAPTCHA mode=show site_key=empty server_key=empty'])
      expect(InstallationConfig.where(name: names).count).to eq(0)
    end

    it '監査行に started と ok が残り、params_digest は mode の digest' do
      store(nil, nil)
      run!('on')
      run!('show')
      on, show = %w[on show].map { |mode| Toybaco::Ops::Audit.params_digest({ 'mode' => mode }) }
      expect(new_rows.pluck(:action, :result, :params_digest)).to eq(
        [['rake.toybaco:e2e_captcha_test_keys', 'started', on], ['rake.toybaco:e2e_captcha_test_keys', 'ok', on],
         ['rake.toybaco:e2e_captcha_test_keys', 'started', show], ['rake.toybaco:e2e_captcha_test_keys', 'ok', show]]
      )
    end
  end

  # commit と rollback を別の DB 接続から見る例。transactional test の中では別の接続から見えないため、この group だけ確定した行を使い、
  # 例の後に元の行(例の前に確定していた行)へ戻す。
  describe '確定した行での transaction・cache・同時実行' do
    self.use_transactional_tests = false

    let!(:saved_rows) { InstallationConfig.where(name: names).map(&:attributes) }

    after do
      InstallationConfig.where(name: names).delete_all
      saved_rows.each { |attributes| InstallationConfig.create!(attributes) }
    end

    # first(この thread の rake)が 2 行を選んだ直後に、second(ブロック)を別の DB 接続の thread で走らせる。second が lock を待つか
    # 終わるまで待ってから first を進め、最後に second の終わりを待つ。second の失敗(abort を含む)はこの例の失敗にする。返り値は両方の
    # 出力の行。
    def interleave(first, &second)
      main = Thread.current
      second_thread = nil
      allow(described_class).to receive(:locked_rows).and_wrap_original do |original|
        rows = original.call
        second_thread ||= start_second(second) if Thread.current == main
        rows
      end
      printed = capture(:stdout) do
        run_task(first)
        raise 'second did not finish' unless second_thread&.join(30)
      end
      raise second_thread[:failure] if second_thread[:failure]

      printed.lines(chomp: true)
    end

    def start_second(action)
      pid = Queue.new
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          pid << connection.raw_connection.backend_pid
          action.call
        end
      rescue SystemExit, StandardError => e
        Thread.current[:failure] = RuntimeError.new("second failed: #{e.class} #{e.message}")
      end
      wait_for_lock_or_end(pid.pop, thread)
      thread
    end

    def wait_for_lock_or_end(pid, thread)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      until thread.join(0.05)
        waiting = ActiveRecord::Base.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}")
        return if waiting == 'Lock'
        raise 'second neither waited for the lock nor finished' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      end
    end

    it '書いた後の読み直しが例外になれば、別の接続から見て 2 行とも書き込み前のままで、GlobalConfig の cache も消さない' do
      store(nil, nil)
      saved = committed_rows
      allow(GlobalConfig).to receive(:clear_cache).and_call_original
      allow(described_class).to receive(:current).and_raise(ActiveRecord::ActiveRecordError, 'read back failed')
      expect { capture(:stdout) { run_task('on') } }.to raise_error(ActiveRecord::ActiveRecordError, 'read back failed')
      expect([committed_rows, saved.size]).to eq([saved, 2])
      expect(GlobalConfig).not_to have_received(:clear_cache)
      expect(new_rows.pluck(:result)).to eq(%w[started failed])
    end

    it '外側の transaction の中で呼ばれても、読み直しの例外で 2 行とも戻る(savepoint。外側の transaction は commit する)' do
      store(nil, nil)
      saved = committed_rows
      allow(described_class).to receive(:current).and_raise(ActiveRecord::ActiveRecordError, 'read back failed')
      ActiveRecord::Base.transaction do
        expect { capture(:stdout) { run_task('on') } }.to raise_error(ActiveRecord::ActiveRecordError, 'read back failed')
      end
      expect(committed_rows).to eq(saved)
    end

    it '行が無い時に 2 つの実行が重なっても advisory lock で直列になり、後の実行は先の実行が確定させた行を読んで書く' do
      InstallationConfig.where(name: names).delete_all
      expect(interleave('on') { run_task('off') }).to contain_exactly(on_line, off_line)
      expect(committed_rows.map(&:first)).to eq(names.sort)
      expect(values).to eq(['', ''])
      expect(new_rows.pluck(:result).sort).to eq(%w[ok ok started started])
    end

    it 'rake が行を選んだ後に SuperAdmin が実鍵を保存しても、行ロックで rake の commit の後に入り、実鍵を test 鍵で上書きしない' do
      store(nil, nil)
      superadmin = -> { InstallationConfig.find_by(name: 'HCAPTCHA_SITE_KEY').update!(value: real_site_key) }
      expect(interleave('on', &superadmin)).to eq([on_line])
      expect(values).to eq([real_site_key, secret])
      expect(refusal('on')).to eq(foreign_keys)
    end
  end
end
