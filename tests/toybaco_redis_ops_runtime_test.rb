# frozen_string_literal: true

# toybaco:redis_census / toybaco:redis_reconcile を、Rails を初期化した後(config/environment。Chatwoot gate の runtime と同じ形)に
# 実 Redis(gate の redis service)で動かす。Rails の初期化は Toybaco::Ops::Digest(運営ダイジェスト)を読み込むので、入れ子の
# 名前空間の Digest が標準ライブラリではなくこの class に解決される回帰(突合の最初の key で NameError)をここで止める。
# fixture は DB 12〜15 にだけ書き(旧 = 12 / 13、新 = 14 / 15)、前後で消す。rake の監査行は既存の spec と同じ方法で後片付けする。
# 使い方(Chatwoot gate の test image の /app で): bundle exec ruby -r./config/environment /contract/tests/toybaco_redis_ops_runtime_test.rb
require 'minitest/autorun'
require 'minitest/mock'
require 'rake'

class ToybacoRedisOpsRuntimeTest < Minitest::Test
  SOURCE_DBS = { 0 => 12, 1 => 13 }.freeze
  TARGET_DBS = { 0 => 14, 1 => 15 }.freeze
  STREAM = 'toybaco:runtime-stream'
  LABELS = { source_tls: 'off', target_tls: 'off', source_id: 'other', target_id: 'other' }.freeze

  def connect(db)
    Redis.new(Redis::Config.app.merge(db: db))
  end

  def flush
    (SOURCE_DBS.values + TARGET_DBS.values).each do |db|
      redis = connect(db)
      redis.flushdb
    ensure
      redis&.close
    end
  end

  def setup
    flush
    @expire_at = (Time.now.to_i + 3600) * 1000
    [SOURCE_DBS, TARGET_DBS].each { |dbs| populate(dbs) }
  end

  def teardown
    flush
  end

  # 標準の 5 型と、consumer group と未処理の entry のある stream。期限は両側で同じ絶対時刻にする。
  def populate(dbs)
    redis = connect(dbs.fetch(0))
    redis.set('alfred:TOYBACO_CONNECTION_STATE::runtime-state', 'state-value')
    redis.pexpireat('alfred:TOYBACO_CONNECTION_STATE::runtime-state', @expire_at)
    redis.rpush('queue:default', %w[job-a job-b])
    redis.sadd('queues', %w[default mailers])
    redis.zadd('schedule', [[1.5, 'job-c'], [2.25, 'job-d']])
    redis.hset('cron_job:runtime', 'cron', '* * * * *', 'status', 'enabled')
    redis.xadd(STREAM, { 'event' => 'a' }, id: '1-0')
    redis.xadd(STREAM, { 'event' => 'b', 'extra' => 'c' }, id: '2-0')
    redis.xgroup(:create, STREAM, 'workers', '0')
    redis.xreadgroup('workers', 'consumer-1', STREAM, '>', count: 1)
    redis.close
    db1 = connect(dbs.fetch(1))
    db1.set('provider:runtime', 'x')
    db1.close
  end

  def client_for(dbs)
    ->(db) { connect(dbs.fetch(db)) }
  end

  # 突合する DB を 0 / 1 に限り、それぞれ fixture の DB へ繋ぐ(gate の Redis の他の DB は読まない)。
  def reconcile
    Toybaco::Ops::RedisKeyScan.stub(:databases, [0, 1]) do
      Toybaco::Ops::RedisReconcile.run(source_for: client_for(SOURCE_DBS), target_for: client_for(TARGET_DBS), labels: LABELS)
    end
  end

  def test_rails_initialization_loads_the_class_that_shadows_digest
    assert defined?(Toybaco::Ops::Digest), 'config/environment loads Toybaco::Ops::Digest'
    refute Toybaco::Ops::Digest.const_defined?(:SHA256), 'a bare Digest inside Toybaco::Ops would not reach ::Digest::SHA256'
  end

  def test_reconcile_matches_every_type_after_rails_initialization
    result = reconcile
    assert result[:match], result[:lines].join("\n")
    assert_match(/verdict result=match failures=0 vanished=0 truncated=false\z/, result[:lines].last)
    matches = result[:lines].grep(/ family /).sum { |line| line[/ match=(\d+) /, 1].to_i }
    assert_equal 7, matches, 'string, list, set, zset, hash and stream in DB 0 and the string in DB 1 are all compared'
    raw = connect(SOURCE_DBS.fetch(0))
    guarded = Toybaco::Ops::RedisCommandGuard.wrap(raw, :reconcile)
    %w[string list set zset hash stream].zip(['alfred:TOYBACO_CONNECTION_STATE::runtime-state', 'queue:default', 'queues', 'schedule',
                                              'cron_job:runtime', STREAM]).each do |type, key|
      assert_match(/\A\h{64}\z/, Toybaco::Ops::RedisValueDigest.digest(guarded, key, type), type)
    end
  ensure
    raw&.close
  end

  def test_reconcile_detects_a_changed_pending_entry_after_rails_initialization
    target = connect(TARGET_DBS.fetch(0))
    target.xack(STREAM, 'workers', '1-0')
    target.close
    result = reconcile
    refute result[:match]
    assert_match(/verdict result=mismatch failures=1 vanished=0 truncated=false\z/, result[:lines].last)
  end

  def test_census_reads_the_fixture_databases_after_rails_initialization
    lines = Toybaco::Ops::RedisCensus.run(Redis::Config.app)
    assert_match(/ done result=ok /, lines.last)
    scanned = lines.grep(/ db db=1[2-5] /).to_h { |line| [line[/ db=(\d+) /, 1], line[/ scanned=(\d+) /, 1].to_i] }
    assert_equal({ '12' => 6, '13' => 1, '14' => 6, '15' => 1 }, scanned)
    assert(lines.any? { |line| line.include?(' client kind=census ') })
  end

  # 本物の rake(:environment・RakeAudit を含む)。出力は census の行で、監査行は started と ok。
  def test_census_rake_runs_after_rails_initialization
    Rails.application.load_tasks unless Rake::Task.task_defined?('toybaco:redis_census')
    baseline = Toybaco::OperatorAction.maximum(:id).to_i
    # 既存の ops_rake_audit_spec と同じく execute で呼ぶ(RakeAudit は execute を包む。:environment は初期化済み)。
    output, = capture_io { Rake::Task['toybaco:redis_census'].execute }
    assert_match(/\ATOYBACO_REDIS_CENSUS start at=\S+ tls=off verify=na target=other$/, output)
    assert_match(/^TOYBACO_REDIS_CENSUS done result=ok /, output)
    rows = Toybaco::OperatorAction.where('id > ?', baseline).order(:id).pluck(:action, :result)
    assert_equal [%w[rake.toybaco:redis_census started], %w[rake.toybaco:redis_census ok]], rows
  ensure
    delete_committed_rows(baseline) if baseline
  end

  # 監査表は追記専用トリガで DELETE を拒むため、test DB の superuser の session でトリガを止めて消す(ops_rake_audit_spec と同じ)。
  def delete_committed_rows(after_id)
    connection = ActiveRecord::Base.connection_db_config.new_connection
    connection.execute('SET session_replication_role = replica')
    connection.execute("DELETE FROM toybaco_operator_actions WHERE id > #{Integer(after_id)}")
  ensure
    connection&.disconnect!
  end
end
