# frozen_string_literal: true

# 定期処理(sidekiq-cron)の自己修復と heartbeat(CW-3)。
# sidekiq-cron の定義は Redis にしかなく、sidekiq の起動時に一度だけ書かれる(上流の config/initializers/sidekiq.rb の
# to_prepare が config/schedule.yml を、トイバコの各 initializer の after_initialize が Sidekiq::Cron::Job.create を書く)。
# ElastiCache は単一ノード・snapshot なしなので、Redis のデータが消えると sidekiq は動き続けたまま定期処理
# (IMAP/Gmail の取り込み、支払い・更新・体験の sweep、ダイジェスト)が全部止まり、ログ件数の alarm も鳴らない。
# そこで sidekiq の server process の中で、sidekiq-cron に依存しない専用の thread が 5 分ごとに登録を照合し、
# 欠けがあれば起動時と同じ方法で書き直して、毎回次の行を出す(infra/terraform/monitoring-cron.tf の alarm が数える)。
#   TOYBACO_CRON_HEARTBEAT jobs=<登録済みの期待の数> expected=<期待の数> reloaded=<true|false>
# - 期待: 上流の schedule.yml の名前と、このプロセスの起動時に source: 'toybaco' で Sidekiq::Cron::Job.create へ渡った定義。
#   sidekiq-cron 2.4 は source を schedule / dynamic にしか残さないので、Redis からはトイバコの定義を見分けられない。
#   引数はこのファイルの読み込み時に singleton class へ prepend した Capture が覚える(各 initializer は変えない)。
#   initializer のファイルは全部 after_initialize より前に読まれるので、トイバコの登録は必ず Capture を通る。
# - 照合: poller と同じ Sidekiq::Cron::Job.all(既定の namespace)の名前と比べる。件数だけでは比べない
#   (消し忘れの古い定義が件数を埋めて、欠けを隠さないようにする)。jobs は期待のうち登録済みの数。
# - 書き直し: 上流の分は上流の initializer と同じ load_from_hash!(source: 'schedule')、トイバコの分は覚えた引数で create。
#   読み直した回の行は reloaded=true で、alarm が鳴る(Redis のデータが消えた合図)。次の回で欠けが残っていれば再び true。
# - 確かめられなかった時(Redis の障害など)は TOYBACO_CRON_CHECK_FAILED を出し、heartbeat は出さない(欠落の alarm で気づく)。
# 手順は docs/managed-deploy.md の「定期処理と受信チャネルの監視」。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module CronHealth
    SOURCE = 'toybaco'
    SCHEDULE_FILE = 'config/schedule.yml'
    INTERVAL_SECONDS = 300
    # 起動直後は上流・sidekiq-cron の startup の読み込みと重ならないよう、少し待ってから 1 回目を出す。
    FIRST_CHECK_SECONDS = 60
    THREAD_NAME = 'toybaco-cron-heartbeat'

    # Sidekiq::Cron::Job.create の前段。引数はそのまま上流へ渡し、登録できたトイバコの定義だけを覚える。
    module Capture
      def create(*args, **kwargs, &)
        created = super
        Toybaco::CronHealth.remember(args.first || kwargs) if created
        created
      end
    end

    @definitions = {}
    @mutex = Mutex.new

    class << self
      def remember(definition)
        return unless definition.is_a?(Hash)

        name = definition[:name] || definition['name']
        source = definition[:source] || definition['source']
        return unless source.to_s == SOURCE && name.is_a?(String) && !name.empty?

        @mutex.synchronize { @definitions[name] = definition.dup.freeze }
      end

      def definitions
        @mutex.synchronize { @definitions.dup }
      end

      def upstream_schedule
        path = Rails.root.join(SCHEDULE_FILE)
        File.exist?(path) ? YAML.load_file(path) : {}
      end

      # 1 回分の照合と書き直し。返り値は heartbeat の値。
      def check!(definitions: self.definitions, schedule: upstream_schedule)
        expected = schedule.keys.map(&:to_s) | definitions.keys
        missing = expected - Sidekiq::Cron::Job.all.map(&:name)
        reload!(missing, schedule, definitions) unless missing.empty?
        result = { jobs: expected.size - missing.size, expected: expected.size, reloaded: !missing.empty? }
        Rails.logger.info("TOYBACO_CRON_HEARTBEAT jobs=#{result[:jobs]} expected=#{result[:expected]} reloaded=#{result[:reloaded]}")
        result
      end

      def beat
        Rails.application.executor.wrap { check! }
      rescue StandardError => e
        Rails.logger.error("TOYBACO_CRON_CHECK_FAILED class=#{e.class}")
        nil
      end

      # sidekiq の server の lifecycle に thread の開始と停止をつなぐ(config は Sidekiq.configure_server の引数)。
      def install(config)
        config.on(:startup) { start }
        config.on(:quiet) { stop }
        config.on(:shutdown) { stop }
      end

      def start
        @mutex.synchronize do
          return if @thread&.alive?

          signal = Queue.new
          @signal = signal
          @thread = Thread.new { run(signal) }
          @thread.name = THREAD_NAME
        end
      end

      def stop
        thread, signal = @mutex.synchronize { [@thread, @signal] }
        signal&.close
        thread&.join(5)
      end

      private

      # close されるまで、待ってから照合する。pop は timeout でも close でも nil を返すので closed? で見分ける。
      def run(signal)
        wait = FIRST_CHECK_SECONDS
        loop do
          signal.pop(timeout: wait)
          break if signal.closed?

          beat
          wait = INTERVAL_SECONDS
        end
      end

      def reload!(missing, schedule, definitions)
        Sidekiq::Cron::Job.load_from_hash!(schedule, source: 'schedule') if missing.intersect?(schedule.keys.map(&:to_s))
        missing.each { |name| Sidekiq::Cron::Job.create(definitions[name].dup) if definitions.key?(name) }
      end
    end
  end
end

if defined?(Sidekiq::Cron::Job)
  capture = Toybaco::CronHealth::Capture
  Sidekiq::Cron::Job.singleton_class.prepend(capture) unless Sidekiq::Cron::Job.singleton_class < capture

  Sidekiq.configure_server { |config| Toybaco::CronHealth.install(config) }
end
