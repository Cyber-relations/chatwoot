# frozen_string_literal: true

require 'rails_helper'
require 'stringio'

# config/initializers/toybaco_cron_heartbeat.rb の定期処理の自己修復と heartbeat(CW-3)。
# sidekiq-cron は試験用の Redis に実際に書き、Redis のデータが消えた状態は cron の key を消して作る。
RSpec.describe Toybaco::CronHealth do
  let(:log) { StringIO.new }
  let(:logger) do
    Logger.new(log, level: :info).tap { |value| value.formatter = proc { |severity, _time, _program, message| "#{severity} #{message}\n" } }
  end
  let(:schedule) do
    {
      'upstream_minutely_probe' => { 'cron' => '*/1 * * * *', 'class' => 'Inboxes::FetchImapEmailInboxesJob', 'queue' => 'scheduled_jobs' },
      'upstream_daily_probe' => { 'cron' => '0 0 * * *', 'class' => 'Internal::TriggerDailyScheduledItemsJob', 'queue' => 'scheduled_jobs' }
    }
  end
  let(:toybaco_definition) do
    { name: 'toybaco_heartbeat_probe', cron: '*/5 * * * *', class: 'Toybaco::GrowthPaymentSweepJob', active_job: true,
      queue: 'scheduled_jobs', source: 'toybaco' }
  end
  let(:definitions) { { 'toybaco_heartbeat_probe' => toybaco_definition.freeze } }

  around do |example|
    saved = described_class.definitions
    Sidekiq::Cron::Job.destroy_all!
    example.run
  ensure
    Sidekiq::Cron::Job.destroy_all!
    described_class.instance_variable_set(:@definitions, saved)
  end

  before { allow(Rails).to receive(:logger).and_return(logger) }

  def boot!
    Sidekiq::Cron::Job.load_from_hash!(schedule.deep_dup, source: 'schedule')
    definitions.each_value { |definition| Sidekiq::Cron::Job.create(definition.dup) }
  end

  def check!
    described_class.check!(definitions: definitions, schedule: schedule.deep_dup)
  end

  def registered
    Sidekiq::Cron::Job.all.map(&:name).sort
  end

  # Redis のデータが消えた状態(sidekiq-cron の key だけを消す。試験の他の key は残す)。
  def wipe_cron_keys!
    Sidekiq.redis do |connection|
      keys = connection.call('KEYS', 'cron_job*')
      connection.call('DEL', *keys) unless keys.empty?
    end
  end

  def heartbeats
    log.string.lines.grep(/TOYBACO_CRON_HEARTBEAT/)
  end

  describe 'Capture(Sidekiq::Cron::Job.create の前段)' do
    it 'Sidekiq::Cron::Job の singleton class に prepend されている' do
      expect(Sidekiq::Cron::Job.singleton_class.ancestors).to include(described_class::Capture)
    end

    it '登録できた source: toybaco の定義だけを覚え、引数はそのまま上流へ渡す' do
      expect(Sidekiq::Cron::Job.create(**toybaco_definition)).to be(true)
      expect(Sidekiq::Cron::Job.create(name: 'dynamic_probe', cron: '* * * * *', class: 'Toybaco::GrowthPaymentSweepJob')).to be(true)
      expect(Sidekiq::Cron::Job.create(name: 'toybaco_invalid_probe', cron: 'not a cron', class: 'X', source: 'toybaco')).to be(false)

      expect(described_class.definitions['toybaco_heartbeat_probe']).to eq(toybaco_definition)
      expect(described_class.definitions.keys).not_to include('dynamic_probe', 'toybaco_invalid_probe')
      expect(Sidekiq::Cron::Job.find('toybaco_heartbeat_probe').cron).to eq('*/5 * * * *')
      expect(registered).to eq(%w[dynamic_probe toybaco_heartbeat_probe])
    end

    it '位置引数の Hash で呼ばれても同じに覚える(書き直しの経路)' do
      expect(Sidekiq::Cron::Job.create(toybaco_definition.dup)).to be(true)
      expect(described_class.definitions['toybaco_heartbeat_probe']).to eq(toybaco_definition)
    end
  end

  describe '.check!' do
    it '登録がそろっていれば読み直さず、jobs と expected が同じ heartbeat を出す' do
      boot!

      expect(check!).to eq(jobs: 3, expected: 3, reloaded: false)
      expect(log.string).to eq("INFO TOYBACO_CRON_HEARTBEAT jobs=3 expected=3 reloaded=false\n")
      expect(registered).to eq(%w[toybaco_heartbeat_probe upstream_daily_probe upstream_minutely_probe])
    end

    it 'Redis の cron が消えたら上流とトイバコの定義を書き直して reloaded=true を出し、次の回は false に戻る' do
      boot!
      wipe_cron_keys!
      expect(registered).to be_empty

      expect(check!).to eq(jobs: 0, expected: 3, reloaded: true)
      expect(registered).to eq(%w[toybaco_heartbeat_probe upstream_daily_probe upstream_minutely_probe])
      restored = Sidekiq::Cron::Job.find('toybaco_heartbeat_probe')
      expect([restored.klass, restored.cron, restored.source, restored.is_active_job?])
        .to eq(['Toybaco::GrowthPaymentSweepJob', '*/5 * * * *', 'dynamic', true])
      expect(Sidekiq::Cron::Job.find('upstream_daily_probe').source).to eq('schedule')

      expect(check!).to eq(jobs: 3, expected: 3, reloaded: false)
      expect(heartbeats).to eq(["INFO TOYBACO_CRON_HEARTBEAT jobs=0 expected=3 reloaded=true\n",
                                "INFO TOYBACO_CRON_HEARTBEAT jobs=3 expected=3 reloaded=false\n"])
    end

    it '件数がそろっていても名前が欠けていれば書き直す(消し忘れの古い定義で欠けを隠さない)' do
      boot!
      Sidekiq::Cron::Job.destroy('toybaco_heartbeat_probe')
      Sidekiq::Cron::Job.create(name: 'removed_long_ago', cron: '0 3 * * *', class: 'Toybaco::GrowthPaymentSweepJob')
      expect(Sidekiq::Cron::Job.count).to eq(3)

      expect(check!).to eq(jobs: 2, expected: 3, reloaded: true)
      expect(registered).to eq(%w[removed_long_ago toybaco_heartbeat_probe upstream_daily_probe upstream_minutely_probe])
    end

    it '上流の分だけが欠けた時は、上流の initializer と同じ load_from_hash! で schedule として戻す' do
      boot!
      Sidekiq::Cron::Job.destroy('upstream_daily_probe')
      allow(Sidekiq::Cron::Job).to receive(:create).and_call_original

      expect(check!).to eq(jobs: 2, expected: 3, reloaded: true)
      expect(Sidekiq::Cron::Job.find('upstream_daily_probe')).to have_attributes(source: 'schedule', cron: '0 0 * * *')
      expect(Sidekiq::Cron::Job).not_to have_received(:create)
    end

    it 'トイバコの分だけが欠けた時は、覚えた定義だけを create し直す' do
      boot!
      Sidekiq::Cron::Job.destroy('toybaco_heartbeat_probe')
      allow(Sidekiq::Cron::Job).to receive(:load_from_hash!).and_call_original

      expect(check!).to eq(jobs: 2, expected: 3, reloaded: true)
      expect(Sidekiq::Cron::Job).not_to have_received(:load_from_hash!)
      expect(registered).to include('toybaco_heartbeat_probe')
    end

    it '期待は上流の config/schedule.yml の名前とトイバコの定義の和(既定の引数)' do
      described_class.instance_variable_set(:@definitions, definitions)
      upstream = YAML.load_file(Rails.root.join('config/schedule.yml')).keys

      result = described_class.check!
      expect(result).to eq(jobs: 0, expected: upstream.size + 1, reloaded: true)
      expect(registered).to match_array(upstream + ['toybaco_heartbeat_probe'])
    end
  end

  describe '.beat' do
    it '確かめられない時(Redis の障害など)は heartbeat を出さず、TOYBACO_CRON_CHECK_FAILED を出す' do
      allow(Sidekiq::Cron::Job).to receive(:all).and_raise(RedisClient::CannotConnectError, 'secret detail')

      expect(described_class.beat).to be_nil
      expect(log.string).to eq("ERROR TOYBACO_CRON_CHECK_FAILED class=RedisClient::CannotConnectError\n")
    end
  end

  describe '専用の thread(sidekiq の lifecycle)' do
    let(:events) { Hash.new { |hash, key| hash[key] = [] } }
    let(:config) do
      recorder = events
      Object.new.tap { |value| value.define_singleton_method(:on) { |event, &block| recorder[event] << block } }
    end
    let(:calls) { Queue.new }

    before do
      stub_const("#{described_class}::FIRST_CHECK_SECONDS", 0.01)
      stub_const("#{described_class}::INTERVAL_SECONDS", 0.01)
      allow(described_class).to receive(:check!) { calls << :checked }
    end

    after { described_class.stop }

    def wait_for_checks(count)
      count.times { Timeout.timeout(5) { calls.pop } }
    end

    def heartbeat_threads
      Thread.list.select { |thread| thread.alive? && thread.name == described_class::THREAD_NAME }
    end

    it 'startup で 1 本だけ動いて照合を繰り返し、quiet / shutdown で止まる(sidekiq-cron に依存しない)' do
      described_class.install(config)
      expect(events.keys).to eq(%i[startup quiet shutdown])

      events[:startup].each(&:call)
      events[:startup].each(&:call)
      wait_for_checks(3)
      expect(heartbeat_threads.size).to eq(1)

      events[:quiet].each(&:call)
      expect(heartbeat_threads).to be_empty
      events[:shutdown].each(&:call)
      expect(heartbeat_threads).to be_empty
    end

    it '照合が例外で終わっても thread は止まらず、次の回も照合する' do
      attempts = 0
      allow(described_class).to receive(:check!) do
        attempts += 1
        calls << attempts
        raise Redis::CannotConnectError, 'down' if attempts == 1
      end

      described_class.start
      wait_for_checks(2)
      expect(heartbeat_threads.size).to eq(1)
      expect(log.string).to include("ERROR TOYBACO_CRON_CHECK_FAILED class=Redis::CannotConnectError\n")
    end
  end
end
