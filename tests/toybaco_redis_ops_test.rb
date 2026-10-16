# frozen_string_literal: true

# Redis の暗号化切替の準備(toybaco:redis_census / toybaco:redis_reconcile)の単体テスト。Redis を使わず、偽の client で
# 系統の分類・出力の形・profile ごとの command・突合の結果を確かめ、rake の例外の扱いは rake の定義を読み込んで確かめる。
# 実 Redis(平文と TLS)での確認は verify/redis-tls/run.sh が同じ library を Chatwoot の image の redis-rb で動かして行う。
# 使い方: ruby tests/toybaco_redis_ops_test.rb(Ruby 3.2 以上と minitest と rake。gem の redis は要らない)
require 'minitest/autorun'
require 'minitest/mock'
require 'rake'
require 'set'
require_relative '../overlay/app/lib/toybaco/ops/redis_endpoint'
require_relative '../overlay/app/lib/toybaco/ops/redis_census'
require_relative '../overlay/app/lib/toybaco/ops/redis_reconcile'

# 読み取りの command だけを受け付ける偽の Redis。書き込みの command が来たら例外にする。
# pipelined は Chatwoot の固定 image の redis-rb 5.0.6 と同じ形(引数なし。全 command を送った後、error の応答があれば最初の 1 件を
# raise する)。2026-10-15 に exception: false を渡す実装が実 Redis でだけ ArgumentError になったため、引数を受け付けない。
class FakeRedis
  # profile ごとに受け付ける command(lib の RedisCommandGuard::PROFILES とは別にここで固定し、テストで一致を確かめる)。
  CENSUS_COMMANDS = %w[INFO CLIENT SCAN TYPE PTTL LLEN SCARD ZCARD HLEN XLEN].freeze
  RECONCILE_COMMANDS = %w[INFO SCAN TIME TYPE PEXPIRETIME GET LLEN LRANGE SSCAN ZCARD ZRANGE HSCAN XLEN XRANGE XINFO XPENDING].freeze
  # redis-rb の Redis::CommandError と同じく、名前が CommandError で終わる command の error と、その派生。
  class CommandError < StandardError; end
  class WrongTypeError < CommandError; end
  class PermissionError < CommandError; end
  class ConnectionError < StandardError; end

  attr_reader :commands

  # allowed: 受け付ける command(profile の一覧)。clock_offset: この Redis の TIME だけを進める・戻す(時計のずれ)。
  # ghosts: { DB => key の配列 }。SCAN には出るが、読む時には無い key(SCAN の後に消えた)。
  # size_error: 要素数の command の error(:connection / :noauth / :permission)。odd_reply: 整数でない応答(:size / :pttl)。
  # guarded_only: 呼び出しが RedisCommandGuard(redis_command_guard.rb)を通った時だけ受け付ける(生の client を wrapper 以外に渡さない)。
  def initialize(store, db, now_ms:, allowed:, resp3: false, client_list: nil, wrongtype: [], size_error: nil, clock_offset: 0, ghosts: {},
                 odd_reply: nil, guarded_only: false)
    @guarded_only = guarded_only
    @replaying = false
    @store = store
    @db = db
    @now_ms = now_ms
    @allowed = allowed
    @odd_reply = odd_reply
    @clock_offset = clock_offset
    @ghosts = ghosts
    @resp3 = resp3
    @client_list = client_list
    @wrongtype = wrongtype
    @size_error = size_error
    @commands = []
    @closed = false
  end

  def closed? = @closed

  def close
    @closed = true
  end

  GUARD_FILE = 'redis_command_guard.rb'

  def self.from_guard?(location)
    location&.path.to_s.end_with?(GUARD_FILE)
  end

  def pipelined
    raise 'raw client used outside the guard' if @guarded_only && !FakeRedis.from_guard?(caller_locations(1, 1).first)

    pipe = Pipe.new(@guarded_only)
    yield pipe
    @replaying = true
    replies = pipe.calls.map do |args|
      call(*args)
    rescue CommandError => e
      e
    end
    @replaying = false
    error = replies.find { |reply| reply.is_a?(CommandError) }
    raise error if error

    replies
  end

  class Pipe
    attr_reader :calls

    def initialize(guarded_only)
      @guarded_only = guarded_only
      @calls = []
    end

    def call(*args)
      raise 'raw pipe used outside the guard' if @guarded_only && !FakeRedis.from_guard?(caller_locations(1, 1).first)

      @calls << args
      nil
    end
  end

  def call(*args)
    raise 'raw client used outside the guard' if @guarded_only && !@replaying && !FakeRedis.from_guard?(caller_locations(1, 1).first)

    name = args.first.to_s.upcase
    raise "command outside the profile: #{name}" unless @allowed.include?(name)

    @commands << name
    send("cmd_#{name.downcase}", *args.drop(1))
  end

  private

  def data = (@store[@db] ||= {})

  def live(key)
    entry = data[key]
    return nil unless entry
    return entry unless entry[:expire] && entry[:expire] <= @now_ms.call

    data.delete(key)
    nil
  end

  def cmd_info(section)
    case section
    when 'keyspace'
      "# Keyspace\r\n" + @store.sort.filter_map do |db, keys|
        alive = keys.keys.count { |key| live_in(db, key) }
        "db#{db}:keys=#{alive},expires=#{keys.count { |_, entry| entry[:expire] }},avg_ttl=0\r\n" if alive.positive?
      end.join
    when 'server' then "# Server\r\nredis_version:7.1.0\r\n"
    when 'replication' then "# Replication\r\nrole:master\r\n"
    when 'memory' then "# Memory\r\nused_memory:1048576\r\nmaxmemory:0\r\nmaxmemory_policy:volatile-lru\r\n"
    when 'persistence' then "# Persistence\r\nrdb_changes_since_last_save:42\r\n"
    when 'stats' then "# Stats\r\nexpired_keys:7\r\nevicted_keys:0\r\n"
    else "# Clients\r\nconnected_clients:3\r\nblocked_clients:1\r\n"
    end
  end

  def live_in(db, key)
    entry = @store[db][key]
    entry && !(entry[:expire] && entry[:expire] <= @now_ms.call)
  end

  def cmd_client(sub)
    raise "CLIENT #{sub} is not a read" unless sub == 'LIST'
    raise ArgumentError, 'ERR unknown command CLIENT' if @client_list == :disabled

    @client_list || "id=7 addr=10.0.0.9:5000 laddr=10.0.0.1:6379 fd=8 name=toybaco-redis-census age=0 idle=0 flags=N db=0 cmd=client|list\n"
  end

  def cmd_time
    ms = @now_ms.call + @clock_offset
    [(ms / 1000).to_s, ((ms % 1000) * 1000).to_s]
  end

  def cmd_scan(cursor, *_options)
    keys = (data.keys.select { |key| live(key) } + @ghosts.fetch(@db, [])).uniq.sort
    start = cursor.to_i
    batch = keys[start, 2] || []
    following = start + 2 >= keys.length ? '0' : (start + 2).to_s
    [following, batch]
  end

  def cmd_type(key) = live(key)&.fetch(:type) || 'none'

  def cmd_pttl(key)
    return 'x' if @odd_reply == :pttl

    entry = live(key)
    return -2 unless entry
    return -1 unless entry[:expire]

    entry[:expire] - @now_ms.call
  end

  def cmd_pexpiretime(key)
    entry = live(key)
    return -2 unless entry

    entry[:expire] || -1
  end

  def typed(key, type)
    entry = live(key)
    return nil unless entry
    raise WrongTypeError, 'WRONGTYPE Operation against a key holding the wrong kind of value' unless entry[:type] == type

    entry[:value]
  end

  SIZE_ERRORS = { connection: [ConnectionError, 'connection lost'], noauth: [CommandError, 'NOAUTH Authentication required.'],
                  permission: [PermissionError, 'NOPERM this user has no permissions to run the command'] }.freeze

  # 要素数の command だけ、TYPE の後に型が変わった key(wrongtype)・WRONGTYPE 以外の error(size_error)・整数でない応答を再現できる。
  def sized(key, type)
    raise(*SIZE_ERRORS.fetch(@size_error)) if @size_error
    raise WrongTypeError, 'WRONGTYPE Operation against a key holding the wrong kind of value' if @wrongtype.include?(key)

    typed(key, type)
  end

  def size_reply(count) = @odd_reply == :size ? count.to_s : count

  def cmd_llen(key) = size_reply(sized(key, 'list').to_a.length)
  def cmd_scard(key) = size_reply(sized(key, 'set').to_a.length)
  def cmd_zcard(key) = size_reply(sized(key, 'zset').to_a.length)
  def cmd_hlen(key) = size_reply(sized(key, 'hash').to_h.length)
  def cmd_xlen(key) = size_reply(sized(key, 'stream')&.fetch(:entries)&.length.to_i)
  def cmd_get(key) = typed(key, 'string')
  def cmd_lrange(key, start, stop) = typed(key, 'list').to_a[start..stop] || []

  def cmd_sscan(key, cursor, *_options)
    ['0', cursor.to_s == '0' ? typed(key, 'set').to_a.reverse : []]
  end

  def cmd_hscan(key, _cursor, *_options)
    ['0', typed(key, 'hash').to_h.to_a.reverse.flatten]
  end

  def cmd_zrange(key, start, stop, _withscores)
    pairs = typed(key, 'zset').to_a.sort_by { |member, score| [score, member] }[start..stop] || []
    @resp3 ? pairs.map { |member, score| [member, score.to_f] } : pairs.flat_map { |member, score| [member, score.to_s] }
  end

  def cmd_xrange(key, from, _to, _count, count)
    entries = typed(key, 'stream').fetch(:entries)
    entries = entries.select { |id, _| id > from.delete_prefix('(') } if from.start_with?('(')
    entries.first(count)
  end

  def cmd_xinfo(sub, key, group = nil)
    stream = typed(key, 'stream')
    rows = sub == 'GROUPS' ? stream.fetch(:groups) : stream.fetch(:consumers).fetch(group)
    rows.map { |row| @resp3 ? row : row.to_a.flatten }
  end

  # XPENDING key group - + count の [ID, consumer, idle, 配った回数]。
  def cmd_xpending(key, group, _start, _end, count)
    typed(key, 'stream').fetch(:pending).fetch(group).first(count)
  end
end

class ToybacoRedisOpsTest < Minitest::Test
  Census = Toybaco::Ops::RedisCensus
  Family = Toybaco::Ops::RedisKeyFamily
  Reconcile = Toybaco::Ops::RedisReconcile
  NOW = 1_800_000_000_000
  SECRETS = %w[STATE-SECRET-1 nonce-value-1 queue-job-secret tok3nXYZsecret mail@example.com opaque-value login-verifier].freeze

  def setup
    @now = NOW
    @clients = []
  end

  PROFILE_COMMANDS = { census: FakeRedis::CENSUS_COMMANDS, reconcile: FakeRedis::RECONCILE_COMMANDS }.freeze

  def client_for(store, profile, **options)
    lambda do |db|
      client = FakeRedis.new(store, db, now_ms: -> { @now }, allowed: PROFILE_COMMANDS.fetch(profile), guarded_only: true, **options)
      @clients << client
      client
    end
  end

  def stream_value(pending: [['1-0', 'c1', 5000, 1]], consumers: %w[c1], idle: 5)
    { entries: [['1-0', %w[a b]], ['2-0', %w[c d]]],
      groups: [{ 'name' => 'g', 'consumers' => consumers.length, 'pending' => pending.length, 'last-delivered-id' => '1-0' }],
      consumers: { 'g' => consumers.map { |name| { 'name' => name, 'pending' => 1, 'idle' => idle } } },
      pending: { 'g' => pending } }
  end

  def store
    {
      0 => {
        'alfred:TOYBACO_CONNECTION_STATE::STATE-SECRET-1' => { type: 'string', value: 'login-verifier', expire: NOW + 600_000 },
        'alfred:TOYBACO_CONNECTION_STATE::STATE-SECRET-2' => { type: 'string', value: 'x', expire: NOW + 30_000 },
        'velma:toybaco:mfa-challenge:v1:abcdef' => { type: 'string', value: 'nonce-value-1', expire: NOW + 120_000 },
        'velma:rack::attack:1:login/email:mail@example.com' => { type: 'string', value: '3', expire: NOW + 300_000 },
        'queue:default' => { type: 'list', value: %w[queue-job-secret job-2] },
        'queues' => { type: 'set', value: %w[default] },
        'schedule' => { type: 'zset', value: [['job-3', 1_800_000_100.5]] },
        'processes' => { type: 'set', value: ['ip-10-0-1-2.internal:1:0123456789ab'] },
        'ip-10-0-1-2.internal:1:0123456789ab' => { type: 'hash', value: { 'info' => '{}' }, expire: NOW + 60_000 },
        'ip-10-0-1-2.internal:1:0123456789ab:work' => { type: 'hash', value: {} },
        'tok3nXYZsecret' => { type: 'string', value: 'opaque-value' },
        'SINGLEWORD:abc' => { type: 'string', value: 'v' },
        'stat:processed' => { type: 'string', value: '10' }
      },
      1 => {
        'login:state-1' => { type: 'string', value: 'login-verifier', expire: NOW + 3_600_000 },
        '{abc123:default}:hits' => { type: 'string', value: '1', expire: NOW + 60_000 },
        'events' => { type: 'stream', value: stream_value }
      }
    }
  end

  def census(data = store, **options)
    Census.lines(client_for: client_for(data, :census, **options), connection: { tls: 'on', verify: 'peer', target: 'toybaco-redis-enc' })
  end

  def field(lines, kind, name, db: 0)
    row = lines.find { |line| line.start_with?("#{Census::PREFIX} #{kind} db=#{db} name=#{name} ") }
    row&.split&.drop(2)&.to_h { |pair| pair.split('=', 2) }
  end

  SIDEKIQ_ID = 'ip-10-0-1-2.ap-northeast-1.compute.internal:7:0123456789ab'

  def test_family_classification
    {
      ['alfred:TOYBACO_CONNECTION_STATE::x', 'string'] => %w[alfred TOYBACO_CONNECTION_STATE],
      ['velma:rack::attack:1:login/ip:1.2.3.4', 'string'] => %w[velma rack-attack],
      ['velma:toybaco:mfa-challenge:v1:aa', 'string'] => %w[velma toybaco.mfa-challenge],
      ['alfred:toybaco:admin_mfa:v1:aa', 'string'] => %w[alfred toybaco.admin_mfa],
      ['alfred:V1:GLOBAL_CONFIG:INSTALLATION_NAME', 'string'] => %w[alfred V1.GLOBAL_CONFIG],
      ['queue:mailers', 'list'] => %w[none queue.mailers],
      ['queue:some_new_queue', 'list'] => %w[none queue.other],
      ['cron_job:sweep:enqueued', 'string'] => %w[none cron_job],
      [SIDEKIQ_ID, 'hash'] => %w[none sidekiq-process],
      ["#{SIDEKIQ_ID}:work", 'hash'] => %w[none sidekiq-process-work],
      ["#{SIDEKIQ_ID}-signals", 'list'] => %w[none sidekiq-process-signals],
      ['j|251015|10:5', 'hash'] => %w[none sidekiq-metrics],
      ['{deadbeef:default}:blocked', 'string'] => %w[none throttler-blocked],
      ['toybaco:upload-rate:v1:post:org', 'string'] => %w[none toybaco.upload-rate],
      ['integration-gmb-v2:org:1:2026', 'string'] => %w[none integration-gmb-v2]
    }.each { |(key, type), expected| assert_equal expected, Family.classify(key, type), key }
    # Sidekiq の process は形と型(hash)の両方で見分ける。SMEMBERS は使わない。
    refute_equal 'sidekiq-process', Family.classify(SIDEKIQ_ID, 'string').last, 'the shape alone is not a process'
    refute_equal 'sidekiq-process', Family.classify('host:1:abc', 'hash').last, 'the identity ends with 12 hex digits'
    refute_equal 'sidekiq-process', Family.classify(SIDEKIQ_ID, nil).last, 'a key that vanished before TYPE is not a process'
    assert Family.printable?('TOYBACO_CONNECTION_STATE')
    assert Family.printable?('queue.mailers')
    assert Family.printable?('queue.other')
    assert_equal 'alfred.TOYBACO-CONNECTION-STATE', Family.label('alfred', 'TOYBACO_CONNECTION_STATE')
    # Chatwoot の key は定数名(CHATWOOT_INSTALLATION_CONFIG_RESET_WARNING)ではなく値の CHATWOOT_CONFIG_RESET_WARNING。
    assert_equal %w[alfred CHATWOOT_CONFIG_RESET_WARNING], Family.classify('alfred:CHATWOOT_CONFIG_RESET_WARNING', 'string')
    assert Family.printable?('CHATWOOT_CONFIG_RESET_WARNING')
    assert_equal %w[velma toybaco.mfa-enrollment-attempts], Family.classify('velma:toybaco:mfa-enrollment-attempts:12', 'string')
    assert Family.printable?('toybaco.mfa-enrollment-attempts')
  end

  # 出せる系統名はコードで定義した既知の語彙だけ。未知の語は件数・文字の種類に関わらず opaque。
  def test_unknown_prefixes_never_print_whatever_their_count
    %w[SINGLEWORD UNKNOWN_PREFIX lowercase-word toybaco.new-thing tok3nXYZsecret queue.mailers2].each do |family|
      refute Family.printable?(family), family
    end
    data = store
    data[0]['UNKNOWN_PREFIX:a'] = { type: 'string', value: 'v' }
    data[0]['UNKNOWN_PREFIX:b'] = { type: 'string', value: 'v' }
    lines = census(data)
    refute_includes lines.join("\n"), 'UNKNOWN', 'two keys with an unknown prefix still do not print the prefix'
    assert_equal '4', field(lines, 'family', 'none.opaque')['keys']
  end

  # ops-rake の Step Summary のマスクは英数字と _ - / + の 40 字以上の並びを <token> にする。既知の系統は出力で読めるよう 40 字未満にする。
  def test_known_families_survive_the_ops_rake_mask
    Family::KNOWN_FAMILIES.each do |family|
      %w[alfred velma none].each do |namespace|
        label = Family.label(namespace, family)
        refute_match(%r{[A-Za-z0-9+/_-]{40,}}, label, label)
      end
    end
  end

  def test_endpoint_label_prints_only_the_elasticache_name
    endpoint = Toybaco::Ops::RedisEndpoint
    assert_equal 'toybaco-redis', endpoint.label('toybaco-redis.abc123.0001.apne1.cache.amazonaws.com')
    assert_equal 'toybaco-redis-enc', endpoint.label('master.toybaco-redis-enc.abc123.apne1.cache.amazonaws.com')
    assert_equal 'toybaco-redis-enc', endpoint.label('replica.toybaco-redis-enc.abc123.apne1.cache.amazonaws.com')
    assert_equal 'toybaco-staging-redis', endpoint.label('TOYBACO-STAGING-REDIS.abc123.0001.apne1.cache.amazonaws.com')
    ['redis-tls.fixture', '10.0.0.1', '', nil, 'cache.amazonaws.com.evil.example', "#{'a' * 41}.abc.apne1.cache.amazonaws.com",
     '1abc.abc.apne1.cache.amazonaws.com', 'a_b.abc.apne1.cache.amazonaws.com'].each do |host|
      assert_equal 'other', endpoint.label(host), host.inspect
    end
  end

  def test_census_connection_comes_from_the_running_config_without_the_host
    peer = Census.connection(url: 'rediss://master.toybaco-redis-enc.abc123.apne1.cache.amazonaws.com:6379',
                             ssl_params: { verify_mode: OpenSSL::SSL::VERIFY_PEER })
    assert_equal({ tls: 'on', verify: 'peer', target: 'toybaco-redis-enc' }, peer)
    none = Census.connection(url: 'rediss://h.cache.amazonaws.com:6379', ssl_params: { verify_mode: OpenSSL::SSL::VERIFY_NONE })
    assert_equal 'none', none[:verify]
    plain = Census.connection(url: 'redis://toybaco-redis.abc123.0001.apne1.cache.amazonaws.com:6379',
                              ssl_params: { verify_mode: OpenSSL::SSL::VERIFY_PEER })
    assert_equal({ tls: 'off', verify: 'na', target: 'toybaco-redis' }, plain)
    assert_equal 'other', Census.connection(url: 'redis://127.0.0.1:6379')[:target]
  end

  def test_census_lines_count_families_ttl_types_and_clients
    lines = census
    assert_match(/\A#{Census::PREFIX} start at=\S+ tls=on verify=peer target=toybaco-redis-enc\z/, lines.first)
    assert_includes lines, "#{Census::PREFIX} server version=7.1.0 role=master used-memory=1048576 maxmemory=0 " \
                           'maxmemory-policy=volatile-lru connected-clients=3 blocked-clients=1 changes-since-save=42 expired-keys=7 ' \
                           'evicted-keys=0'
    state = field(lines, 'family', 'alfred.TOYBACO-CONNECTION-STATE')
    assert_equal({ 'keys' => '2', 'string' => '2', 'ttl-le-1m' => '1', 'ttl-le-1h' => '1', 'ttl-none' => '0' },
                 state.slice('keys', 'string', 'ttl-le-1m', 'ttl-le-1h', 'ttl-none'))
    queue = field(lines, 'family', 'none.queue.default')
    assert_equal %w[1 1 2 1], queue.values_at('keys', 'list', 'items', 'ttl-none')
    assert_equal '1', field(lines, 'family', 'none.sidekiq-process')['hash']
    assert_equal '1', field(lines, 'family', 'none.sidekiq-process-work')['keys']
    assert_equal '1', field(lines, 'family', 'velma.rack-attack')['ttl-le-1h']
    opaque = field(lines, 'family', 'none.opaque')
    assert_equal '2', opaque['keys'], 'the token key and the single unknown family are both opaque'
    assert_equal '1', field(lines, 'family', 'none.throttler-hits', db: 1)['keys']
    assert_equal %w[1 1 2], field(lines, 'family', 'none.opaque', db: 1).values_at('keys', 'stream', 'items'),
                 'a single unknown stream key in DB 1 is opaque'
    assert_equal %w[1 1], field(lines, 'family', 'none.login', db: 1).values_at('keys', 'ttl-le-1h')
    assert_includes lines, "#{Census::PREFIX} db db=0 keys-info=13 expires-info=5 scanned=13 truncated=false families=11"
    assert_includes lines, "#{Census::PREFIX} clients total=1 others=0 distinct-hosts=0"
    assert_includes lines, "#{Census::PREFIX} client kind=census db=0 cmd=client.list flags=N count=1"
    assert_match(/\A#{Census::PREFIX} done result=ok databases=2 elapsed-ms=\d+\z/, lines.last)
    assert @clients.all?(&:closed?), 'every client is closed'
  end

  def test_census_never_prints_key_names_or_values_and_sends_only_reads
    output = census.join("\n")
    SECRETS.each { |secret| refute_includes output, secret }
    refute_includes output, 'SINGLEWORD'
    refute_includes output, 'ip-10-0-1-2'
    refute_includes output, '10.0.0.9'
    commands = @clients.flat_map(&:commands).uniq
    assert_empty commands - FakeRedis::CENSUS_COMMANDS
    %w[GET LRANGE SMEMBERS SSCAN HSCAN ZRANGE XRANGE].each { |command| refute_includes commands, command, 'the census never reads values' }
  end

  def test_census_counts_other_clients_by_kind_without_names_or_addresses
    list = <<~LIST
      id=7 addr=10.0.0.9:5000 laddr=10.0.0.1:6379 fd=8 name=toybaco-redis-census age=0 idle=0 flags=N db=0 cmd=client|list
      id=8 addr=10.0.2.3:6000 laddr=10.0.0.1:6379 fd=9 name=ActionCable-PID-1234 age=9 idle=1 flags=P db=0 cmd=subscribe
      id=9 addr=10.0.2.3:6001 laddr=10.0.0.1:6379 fd=10 name= age=9 idle=0 flags=b db=0 cmd=brpop
      id=10 addr=10.0.2.4:6002 laddr=10.0.0.1:6379 fd=11 name=deadbeefcafebabe00 age=9 idle=0 flags=N db=1 cmd=evalsha
      id=11 addr=10.0.2.5:6003 laddr=10.0.0.1:6379 fd=12 name=Sidekiq-server-PID-77 age=9 idle=0 flags=b db=0 cmd=brpop
      id=12 addr=10.0.2.6:6004 laddr=10.0.0.1:6379 fd=13 name= age=9 idle=0 flags=N db=1 cmd=get
      id=13 addr=10.0.2.6:6005 laddr=10.0.0.1:6379 fd=14 name=mail@example.com-secret-client age=9 idle=0 flags=N db=0 cmd=get
    LIST
    lines = census(client_list: list)
    assert_includes lines, "#{Census::PREFIX} clients total=7 others=6 distinct-hosts=4"
    assert_includes lines, "#{Census::PREFIX} client kind=actioncable db=0 cmd=subscribe flags=P count=1"
    assert_includes lines, "#{Census::PREFIX} client kind=chatwoot db=0 cmd=brpop flags=b count=1"
    assert_includes lines, "#{Census::PREFIX} client kind=other db=1 cmd=evalsha flags=N count=1"
    assert_includes lines, "#{Census::PREFIX} client kind=sidekiq db=0 cmd=brpop flags=b count=1"
    assert_includes lines, "#{Census::PREFIX} client kind=postiz db=1 cmd=get flags=N count=1"
    assert_includes lines, "#{Census::PREFIX} client kind=other db=0 cmd=get flags=N count=1"
    kinds = lines.filter_map { |line| line[/ client kind=(\S+) /, 1] }.uniq
    assert_empty kinds - Toybaco::Ops::RedisClientList::KINDS
    refute_match(/10\.0\.2\.|6000|1234|deadbeef|Sidekiq-server|ActionCable-PID|mail@example|secret-client/, lines.join("\n"),
                 'client names, addresses and ports are never printed')
    lines.select { |line| line.include?(' client ') }.each { |line| refute_includes line, 'name=' }
  end

  def test_census_reports_unavailable_client_list
    lines = census(client_list: :disabled)
    assert_includes lines, "#{Census::PREFIX} clients unavailable=ArgumentError"
    assert_match(/done result=ok/, lines.last)
  end

  def test_census_counts_a_key_whose_type_changed_after_type_as_zero_items
    lines = census(wrongtype: ['queue:default'])
    assert_equal %w[1 1 0], field(lines, 'family', 'none.queue.default').values_at('keys', 'list', 'items')
    assert_equal '1', field(lines, 'family', 'none.sidekiq-process')['hash'], 'the rest of the batch is still counted'
    assert_equal %w[1 2], field(lines, 'family', 'none.opaque', db: 1).values_at('keys', 'items'), 'other databases are unaffected'
    assert_match(/done result=ok/, lines.last)
  end

  def test_census_stops_on_a_connection_error_instead_of_counting_zero
    assert_raises(FakeRedis::ConnectionError) { census(size_error: :connection) }
    assert @clients.all?(&:closed?), 'every client is closed even when the census stops'
  end

  # WRONGTYPE だけを 0 に数える。LOADING・NOAUTH・NOPERM などの command の error を空の key と同じにしない。
  def test_census_counts_only_wrongtype_as_zero_and_stops_on_other_command_errors
    assert_raises(FakeRedis::CommandError) { census(size_error: :noauth) }
    assert_raises(FakeRedis::PermissionError) { census(size_error: :permission) }
    scan = Toybaco::Ops::RedisKeyScan
    assert scan.wrongtype_error?(FakeRedis::WrongTypeError.new('WRONGTYPE Operation against a key'))
    assert scan.wrongtype_error?(FakeRedis::CommandError.new('WRONGTYPE Operation against a key'))
    refute scan.wrongtype_error?(FakeRedis::CommandError.new('NOAUTH Authentication required.'))
    refute scan.wrongtype_error?(FakeRedis::PermissionError.new('NOPERM no permissions'))
    refute scan.wrongtype_error?(FakeRedis::CommandError.new('LOADING Redis is loading the dataset in memory'))
    refute scan.wrongtype_error?(FakeRedis::ConnectionError.new('connection lost'))
  end

  # 整数のはずの応答が整数でなければ止める(失敗を 0 や空の key と同じにしない)。
  def test_census_stops_on_a_non_integer_reply
    assert_raises(Toybaco::Ops::RedisKeyScan::UnexpectedReply) { census(odd_reply: :size) }
    assert_raises(Toybaco::Ops::RedisKeyScan::UnexpectedReply) { census(odd_reply: :pttl) }
    error = assert_raises(Toybaco::Ops::RedisKeyScan::UnexpectedReply) { Toybaco::Ops::RedisKeyScan.integer!('STATE-SECRET-1') }
    refute_includes error.message, 'STATE-SECRET-1', 'the reply is not echoed'
  end

  def scanned(count, max)
    data = { 0 => (1..count).to_h { |n| ["k#{n}", { type: 'string', value: 'v' }] } }
    Census.stub_const(:MAX_KEYS, max) { census(data) }.find { |line| line.include?(' db db=0 ') }
  end

  # cursor が 0 に戻り、key がちょうど上限の件数なら完了(打ち切りにしない)。上限を超えた時だけ打ち切る。
  def test_census_truncates_only_beyond_the_key_limit
    assert_includes scanned(3, 3), 'scanned=3 truncated=false'
    assert_includes scanned(4, 3), 'scanned=3 truncated=true'
    assert_includes scanned(5, 3), 'scanned=3 truncated=true'
    assert_includes scanned(2, 3), 'scanned=2 truncated=false'
  end

  # 送れる command は profile の allowlist だけ。census は metadata、reconcile は値の読み取りまで。
  def test_command_guard_profiles_are_fixed_and_refuse_writes
    guard = Toybaco::Ops::RedisCommandGuard
    assert_equal FakeRedis::CENSUS_COMMANDS.sort, guard::PROFILES.fetch(:census).sort
    assert_equal FakeRedis::RECONCILE_COMMANDS.sort, guard::PROFILES.fetch(:reconcile).sort
    assert_equal({ 'CLIENT' => %w[LIST], 'XINFO' => %w[GROUPS CONSUMERS] }, guard::SUBCOMMANDS)
    raw = FakeRedis.new(store, 0, now_ms: -> { NOW }, allowed: FakeRedis::CENSUS_COMMANDS + %w[DEL SET GET])
    %i[census reconcile].each do |profile|
      wrapped = guard.wrap(raw, profile)
      [%w[DEL k], %w[SET k v], %w[FLUSHALL], %w[CLIENT KILL x], %w[CLIENT ID], %w[CONFIG GET maxmemory], %w[XINFO STREAM k],
       %w[EVAL x 0], %w[SMEMBERS processes]].each do |command|
        error = assert_raises(guard::Refused, "#{profile} #{command.first}") { wrapped.call(*command) }
        refute_includes error.message, 'k v', 'arguments are not echoed'
        assert_raises(guard::Refused) { wrapped.pipelined { |pipe| pipe.call(*command) } }
      end
    end
    assert_raises(guard::Refused) { guard.wrap(raw, :census).call('GET', 'k') }
    refute_includes raw.commands, 'DEL'
    refute_includes raw.commands, 'GET'
    Toybaco::Ops::RedisKeyScan.with_client(->(_db) { raw }, 0, :census) do |client|
      assert_raises(guard::Refused) { client.call('DEL', 'k') }
    end
    assert raw.closed?
  end

  # wrapper は profile(census / reconcile)からしか作れない。送れる command の一覧を外から渡させない。
  def test_command_guard_is_built_only_from_a_profile
    guard = Toybaco::Ops::RedisCommandGuard
    raw = FakeRedis.new(store, 0, now_ms: -> { NOW }, allowed: FakeRedis::RECONCILE_COMMANDS + %w[DEL])
    [%w[DEL GET], 'census', :admin, nil, guard::PROFILES.fetch(:reconcile)].each do |profile|
      assert_raises(ArgumentError, profile.inspect) { guard::Client.new(raw, profile) }
      assert_raises(ArgumentError, profile.inspect) { guard.wrap(raw, profile) }
    end
    refute_includes raw.commands, 'DEL'
  end

  # to_s / upcase を偽る String の派生。中身は DEL。
  class LyingString < String
    def to_s = 'GET'
    def upcase = 'GET'
    def to_str = 'GET'
  end

  # 判定にも送信にも、名前を String の新しい複製にして大文字にした値を使う(偽る object を client に渡さない)。
  def test_command_guard_checks_and_sends_the_same_plain_name
    guard = Toybaco::Ops::RedisCommandGuard
    sent = []
    recorder = Object.new
    recorder.define_singleton_method(:call) { |*command| sent << command }
    recorder.define_singleton_method(:close) {}
    wrapped = guard.wrap(recorder, :reconcile)
    assert_raises(guard::Refused) { wrapped.call(LyingString.new('DEL'), 'k') }
    assert_raises(guard::Refused) { wrapped.call(LyingString.new('xinfo'), LyingString.new('STREAM'), 'k') }
    assert_empty sent, 'nothing reaches the client when the real name is refused'
    wrapped.call(:get, 'k')
    wrapped.call('xinfo', 'groups', 'k')
    assert_equal [%w[GET k], %w[XINFO GROUPS k]], sent
    assert(sent.flat_map { |command| command.first(1) }.all? { |name| name.instance_of?(String) }, 'the name sent is a plain String')
  end

  # 生の client は with_client の中でだけ作り、wrapper 以外に渡さない。Redis.new を呼ぶのは census の run の client_for だけ。
  def test_raw_clients_are_created_only_inside_with_client
    sources = Dir[File.expand_path('../overlay/app/lib/toybaco/ops/redis_*.rb', __dir__)].to_h { |path| [File.basename(path), File.read(path)] }
    code = sources.transform_values { |text| text.lines.reject { |line| line.lstrip.start_with?('#') }.join }
    news = code.flat_map { |name, text| text.scan(/(?:::)?\bRedis\.new\b/).map { name } }
    assert_equal ['redis_census.rb'], news, 'only the census run builds a client (inside its client_for)'
    assert_match(/def run\(config\)\n\s+client_for = ->\(db\) \{ ::Redis\.new\(/, code.fetch('redis_census.rb'))
    calls = code.flat_map { |name, text| text.scan(/client_for\.call\(/).map { name } }
    assert_equal ['redis_key_scan.rb'], calls, 'client_for is called only by RedisKeyScan.with_client'
    assert_match(/client = client_for\.call\(db\)\n\s+yield RedisCommandGuard\.wrap\(client, profile\)/, code.fetch('redis_key_scan.rb'))
  end

  # 入れ子の名前空間(Toybaco::Ops の下)では Digest が Toybaco::Ops::Digest(運営ダイジェスト)に解決される。lib の標準ライブラリと gem の
  # 定数は :: を付ける(rake のブロックは最上位の lexical scope なので対象にしない)。
  def test_stdlib_constants_are_absolute_in_nested_namespaces
    pattern = /(?<![:\w])(Digest|OpenSSL|URI|Time|Process|Redis|SecureRandom|Set|String|StandardError|ArgumentError)(?=::|\.)/
    paths = Dir[File.expand_path('../overlay/app/lib/toybaco/ops/redis_*.rb', __dir__)]
    offenders = paths.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        "#{File.basename(path)}:#{index + 1}" if !line.lstrip.start_with?('#') && line.split(' # ').first.match?(pattern)
      end
    end
    assert_empty offenders
    Toybaco::Ops.const_set(:Digest, Class.new) unless Toybaco::Ops.const_defined?(:Digest, false)
    assert_match(/\A\h{64}\z/, Toybaco::Ops::RedisValueDigest.digest(reader(store, 0), 'queue:default', 'list'),
                 'the digest still works while Toybaco::Ops::Digest exists')
  end

  LABELS = { source_tls: 'off', target_tls: 'on', source_id: 'toybaco-redis', target_id: 'toybaco-redis-enc' }.freeze

  def reconcile(source, target, target_options: {}, **options)
    Reconcile.run(source_for: client_for(source, :reconcile, **options), target_for: client_for(target, :reconcile, **target_options),
                  labels: LABELS)
  end

  def reconcile_row(result, name, db: 0)
    row = result[:lines].find { |line| line.include?(' family ') && line.include?(" db=#{db} ") && line.include?(" name=#{name} ") }
    row&.split&.drop(2)&.to_h { |pair| pair.split('=', 2) }
  end

  def test_reconcile_matches_an_exact_restore_even_across_resp_versions
    result = reconcile(store, store, resp3: true)
    assert result[:match], result[:lines].join("\n")
    assert_match(/\A#{Reconcile::PREFIX} start at=\S+ source-tls=off target-tls=on source-id=toybaco-redis target-id=toybaco-redis-enc\z/,
                 result[:lines].first)
    assert_match(/verdict result=match failures=0 vanished=0 truncated=false\z/, result[:lines].last)
    assert_equal '1', reconcile_row(result, 'none.queue.default')['match']
    output = result[:lines].join("\n")
    SECRETS.each { |secret| refute_includes output, secret }
    assert_empty @clients.flat_map(&:commands).uniq - FakeRedis::RECONCILE_COMMANDS
    assert_includes @clients.flat_map(&:commands), 'XPENDING'
  end

  def test_reconcile_fails_on_a_consumed_nonce_and_a_new_queue_item_after_the_snapshot
    target = store
    source = store
    source[0].delete('alfred:TOYBACO_CONNECTION_STATE::STATE-SECRET-1')
    source[0]['queue:default'][:value] += ['job-after-snapshot']
    source[0]['queue:low'] = { type: 'list', value: ['late'] }
    result = reconcile(source, target)
    refute result[:match]
    assert_equal %w[1 1], reconcile_row(result, 'alfred.TOYBACO-CONNECTION-STATE').values_at('extra', 'match')
    assert_equal '1', reconcile_row(result, 'none.queue.default')['value-mismatch']
    assert_equal '1', reconcile_row(result, 'none.queue.low')['missing']
    assert_match(/verdict result=mismatch failures=3 vanished=0 truncated=false\z/, result[:lines].last)
  end

  def test_reconcile_allows_keys_that_expired_between_reads_and_flags_ttl_type_and_size_drift
    target = store
    source = store
    @now = NOW + 31_000 # STATE-SECRET-2 has expired on both sides
    source[0]['velma:toybaco:mfa-challenge:v1:abcdef'][:expire] = NOW + 999_000
    source[0]['stat:processed'] = { type: 'list', value: ['10'] }
    result = Toybaco::Ops::RedisValueDigest.stub_const(:MAX_ELEMENTS, 1) { reconcile(source, target) }
    refute result[:match]
    assert_equal '1', reconcile_row(result, 'velma.toybaco.mfa-challenge')['expiry-mismatch']
    assert_equal '1', reconcile_row(result, 'none.stat')['type-mismatch']
    assert_equal '1', reconcile_row(result, 'none.queue.default')['too-large']
    assert_equal '0', reconcile_row(result, 'alfred.TOYBACO-CONNECTION-STATE')['missing']
  end

  def test_reconcile_counts_expired_one_sided_keys
    assert_equal 'expired', Reconcile.outcome({ type: 'string', expire: NOW - 1, digest: 'a' }, nil, NOW)
    assert_equal 'missing', Reconcile.outcome({ type: 'string', expire: -1, digest: 'a' }, nil, NOW)
    assert_equal 'expired', Reconcile.outcome(nil, { type: 'string', expire: NOW, digest: 'a' }, NOW)
    assert_equal 'extra', Reconcile.outcome(nil, { type: 'string', expire: NOW + 1, digest: 'a' }, NOW)
    assert_equal 'missing', Reconcile.outcome({ type: 'string', expire: NOW + 1, digest: 'a' }, nil, NOW),
                 'a deadline after the pre-read time is not expired, even if it passes while reading'
    assert_equal 'vanished', Reconcile.outcome(nil, nil, NOW), 'gone on both sides without a deadline is vanished, not expired'
    assert_equal 'unsupported', Reconcile.outcome({ type: 'x', expire: -1, digest: :unsupported }, { type: 'x', expire: -1, digest: 'a' }, NOW)
  end

  # 期限の比べは host の時計ではなく、batch を読む前の両側の TIME の小さい方。進んだ側の時計で期限切れにしない。
  def test_reconcile_uses_the_earlier_redis_clock_taken_before_reading
    source = store
    target = store
    source[0]['alfred:TOYBACO_GMAIL_FETCH::lease-x'] = { type: 'string', value: 'v', expire: NOW + 5_000 }
    source[0]['alfred:TOYBACO_GMAIL_FETCH::lease-y'] = { type: 'string', value: 'v', expire: NOW + 5_000 }
    # target の時計は 10 秒進んでいて、その時計では 2 つの lease は既に期限切れで消えている。
    result = reconcile(source, target, target_options: { clock_offset: 10_000 })
    refute result[:match], 'a lease that is still live on the slower clock must not be excused as expired'
    assert_equal %w[2 0], reconcile_row(result, 'alfred.TOYBACO-GMAIL-FETCH').values_at('missing', 'expired')
    behind = reconcile(source, target, clock_offset: -10_000)
    refute behind[:match], 'the earlier clock is used whichever side is behind'
    assert_equal '2', reconcile_row(behind, 'alfred.TOYBACO-GMAIL-FETCH')['missing']
    assert_includes @clients.flat_map(&:commands), 'TIME'
  end

  def test_reconcile_counts_vanished_keys_without_failing_and_prints_them
    ghosts = { 0 => %w[alfred:TOYBACO_MICROSOFT_FETCH::a alfred:TOYBACO_MICROSOFT_FETCH::b] }
    result = reconcile(store, store, ghosts: ghosts, target_options: { ghosts: ghosts })
    assert result[:match], result[:lines].join("\n")
    assert_equal %w[2 0], reconcile_row(result, 'alfred.TOYBACO-MICROSOFT-FETCH').values_at('vanished', 'expired')
    assert_match(/verdict result=match failures=0 vanished=2 truncated=false\z/, result[:lines].last)
  end

  # digest は String か Symbol。nil 同士・片側 nil・未知の Symbol を一致や未知の結果名にしない。
  def test_reconcile_never_matches_missing_or_unknown_digests
    side = ->(digest) { { type: 'string', expire: -1, digest: digest } }
    assert_equal 'unsupported', Reconcile.compare(side.call(nil), side.call(nil))
    assert_equal 'unsupported', Reconcile.compare(side.call('a'), side.call(nil))
    assert_equal 'unsupported', Reconcile.compare(side.call(:weird_result), side.call('a'))
    assert_equal 'unsupported', Reconcile.compare(side.call(:match), side.call(:match)), 'a Symbol can never claim a passing result'
    assert_equal 'too-large', Reconcile.compare(side.call(:too_large), side.call('a'))
    assert_equal 'match', Reconcile.compare(side.call('a'), side.call('a'))
    outcomes = [nil, 'a', :weird_result, :too_large, :unsupported].product([nil, 'a', :weird_result]).map do |left, right|
      Reconcile.compare(side.call(left), side.call(right))
    end
    assert_empty outcomes.uniq - Reconcile::OUTCOMES, 'every comparison lands on a known outcome'
  end

  def test_value_digest_never_returns_nil_even_for_a_key_that_vanished_after_type
    digest = Toybaco::Ops::RedisValueDigest
    client = FakeRedis.new(store, 0, now_ms: -> { NOW }, allowed: FakeRedis::RECONCILE_COMMANDS)
    { 'string' => 'tok3nXYZsecret', 'list' => 'queue:default', 'set' => 'queues', 'zset' => 'schedule', 'hash' => 'processes' }
      .each do |type, key|
      [key, 'no-such-key'].each do |name|
        value = digest.digest(client, name, type == 'hash' && name == key ? 'set' : type)
        assert(value.is_a?(String) || value.is_a?(Symbol), "#{type} #{name}: #{value.inspect}")
      end
    end
    stream = digest.digest(FakeRedis.new(store, 1, now_ms: -> { NOW }, allowed: FakeRedis::RECONCILE_COMMANDS), 'events', 'stream')
    assert_kind_of String, stream
  end

  # 名前空間は固定の語(alfred / velma / none、出力で other)だけ。key 由来の文字列を名前空間として出さない。
  NAMESPACE_PROBES = ['STATE-SECRET-1:x', 'mail@example.com:1', 'alfred', 'alfred:', 'velma::', 'ALFRED:x', 'tok3n:alfred:x', "a\nb:c", '',
                      ':x', 'sidekiq:x', 'postiz:x', 'toybaco:x', 'other:x', 'none:x', "alfred\0:x", 'alfred :x'].freeze

  def namespaces_seen
    NAMESPACE_PROBES.map { |key| Family.classify(key, 'string').first }.uniq
  end

  def assert_fixed_namespaces
    assert_empty namespaces_seen - %w[alfred velma none], 'namespace must come from the fixed vocabulary'
    NAMESPACE_PROBES.each do |key|
      label = Family.label(*Family.classify(key, 'string'))
      assert_match(/\A(?:alfred|velma|none|other)\./, label, key.inspect)
    end
  end

  def test_namespace_is_a_fixed_vocabulary
    assert_fixed_namespaces
    assert_equal 'other.x', Family.label('STATE-SECRET-1', 'x'), 'the label never prints an unknown namespace'
    lines = census + reconcile(store, store)[:lines]
    names = lines.filter_map { |line| line[/ family db=\d+ name=([^ ]+) /, 1] }
    refute_empty names
    names.each { |name| assert_match(/\A(?:alfred|velma|none|other)\./, name) }
  end

  def test_namespace_check_rejects_a_key_derived_namespace
    mutated = ->(key) { key.split(':', 2).then { |head, rest| [head.to_s, rest.to_s] } }
    Family.stub(:split_namespace, mutated) do
      assert_raises(Minitest::Assertion) { assert_fixed_namespaces }
    end
  end

  def test_reconcile_endpoints_are_elasticache_names_only
    endpoint = Toybaco::Ops::RedisEndpoint
    assert_equal({ scheme: 'rediss', host: 'master.toybaco-redis-enc.abc123.apne1.cache.amazonaws.com' },
                 endpoint.parse('rediss:master.toybaco-redis-enc.abc123.apne1.cache.amazonaws.com'))
    assert_equal({ scheme: 'redis', host: 'toybaco-redis.abc123.0001.apne1.cache.amazonaws.com' },
                 endpoint.parse('redis:toybaco-redis.abc123.0001.apne1.cache.amazonaws.com'))
    ['', 'rediss:', 'https:x.cache.amazonaws.com', 'rediss://x.cache.amazonaws.com', 'rediss:X.cache.amazonaws.com',
     'rediss:x.cache.amazonaws.com:6380', 'rediss:x.cache.amazonaws.com/1', 'rediss:user@x.cache.amazonaws.com',
     'rediss:10.0.0.1', 'rediss:redis.example.com', 'rediss:x.cache.amazonaws.com.evil.example', nil].each do |raw|
      error = assert_raises(ArgumentError, raw.inspect) { endpoint.parse(raw) }
      refute_includes error.message, 'evil', 'the rejected value is not echoed'
    end
    assert_equal({ scheme: 'rediss', host: 'redis-tls.fixture' }, endpoint.parse('rediss:redis-tls.fixture', required_suffix: nil))
    assert_equal(LABELS, endpoint.labels(endpoint.parse('redis:toybaco-redis.abc123.0001.apne1.cache.amazonaws.com'),
                                         endpoint.parse('rediss:master.toybaco-redis-enc.abc123.apne1.cache.amazonaws.com')))
    tls = endpoint.options({ scheme: 'rediss', host: 'h.cache.amazonaws.com' }, 1)
    assert_equal [true, OpenSSL::SSL::VERIFY_PEER, 1, 6379], [tls[:ssl], tls.dig(:ssl_params, :verify_mode), tls[:db], tls[:port]]
    refute endpoint.options({ scheme: 'redis', host: 'h.cache.amazonaws.com' }, 0).key?(:ssl)
  end

  def reader(data, db, resp3: false)
    FakeRedis.new(data, db, now_ms: -> { NOW }, allowed: FakeRedis::RECONCILE_COMMANDS, resp3: resp3)
  end

  def test_value_digest_is_the_same_for_resp2_and_resp3_shapes
    digest = Toybaco::Ops::RedisValueDigest
    resp2 = reader(store, 0)
    resp3 = reader(store, 0, resp3: true)
    assert_equal digest.digest(resp2, 'schedule', 'zset'), digest.digest(resp3, 'schedule', 'zset')
    stream2 = reader(store, 1)
    stream3 = reader(store, 1, resp3: true)
    assert_equal digest.digest(stream2, 'events', 'stream'), digest.digest(stream3, 'events', 'stream')
    refute_equal digest.digest(resp2, 'queue:default', 'list'), digest.digest(resp2, 'queues', 'set')
    assert_equal :unsupported, digest.digest(resp2, 'x', 'ReJSON-RL')
  end

  def stream_digest(**value)
    data = store
    data[1]['events'] = { type: 'stream', value: stream_value(**value) }
    Toybaco::Ops::RedisValueDigest.digest(reader(data, 1), 'events', 'stream')
  end

  # consumer group の未処理の entry(ID・consumer・配った回数)と consumer の名前も比べる。idle 時間は比べない。
  def test_stream_digest_includes_pending_entries_of_consumer_groups
    base = stream_digest
    assert_equal base, stream_digest(idle: 99_999), 'idle time is not compared'
    refute_equal base, stream_digest(pending: [['2-0', 'c1', 5000, 1]]), 'a different pending ID is a different value'
    refute_equal base, stream_digest(pending: [['1-0', 'c2', 5000, 1]], consumers: %w[c1 c2]), 'the owning consumer is compared'
    refute_equal base, stream_digest(pending: [['1-0', 'c1', 5000, 2]]), 'the delivery count is compared'
    refute_equal base, stream_digest(consumers: %w[c1 c3]), 'consumer names are compared'
    assert_equal base, stream_digest(pending: [['1-0', 'c1', 1, 1]]), 'the idle column of XPENDING is not compared'
    source = store
    target = store
    target[1]['events'] = { type: 'stream', value: stream_value(pending: [['2-0', 'c1', 5000, 1]]) }
    result = reconcile(source, target)
    refute result[:match]
    assert_equal '1', reconcile_row(result, 'none.opaque', db: 1)['value-mismatch']
  end

  def entries_digest(entries)
    data = store
    data[1]['events'] = { type: 'stream', value: stream_value.merge(entries: entries) }
    Toybaco::Ops::RedisValueDigest.digest(reader(data, 1), 'events', 'stream')
  end

  # entry の境目と件数を保つ。値の並びを平らにすると同じになる、構造の違う stream を別の値にする。
  def test_stream_digest_keeps_entry_boundaries
    three = entries_digest([['1-0', %w[f a]], ['2-0', %w[g b]], ['3-0', %w[h c]]])
    one = entries_digest([['1-0', %w[f a 2-0 g b 3-0 h c]]])
    refute_equal three, one, 'three entries are not one entry with the same flattened scalars'
    split = entries_digest([['1-0', %w[f a]], ['2-0', %w[g b c d]]])
    shifted = entries_digest([['1-0', %w[f a 2-0 g]], ['b', %w[c d]]])
    refute_equal split, shifted, 'the same number of entries with different boundaries differ'
    assert_equal three, entries_digest([['1-0', %w[f a]], ['2-0', %w[g b]], ['3-0', %w[h c]]])
  end

  def test_stream_with_too_many_pending_entries_is_too_large
    Toybaco::Ops::RedisValueDigest.stub_const(:MAX_PENDING, 0) do
      assert_equal :too_large, stream_digest
      result = reconcile(store, store)
      refute result[:match], 'a stream whose pending entries cannot be compared stops the cutover'
      assert_equal '1', reconcile_row(result, 'none.opaque', db: 1)['too-large']
    end
  end
end

# rake の定義を読み込み、Redis の例外の文(command・key 名を含み得る)を出さずに class 名だけを出して exit 1 で止まることを確かめる。
# gem の redis は読み込まず、Redis と Redis::Config をここで最小に定義する。
class Redis
  class SecretFailure < StandardError; end

  module Config
    def self.app = { url: 'redis://toybaco-redis.abc123.0001.apne1.cache.amazonaws.com:6379', ssl_params: {} }
  end

  def self.new(*)
    raise SecretFailure, 'ERR GET alfred:TOYBACO_CONNECTION_STATE::STATE-SECRET-1 on toybaco-redis.abc123.0001.apne1.cache.amazonaws.com'
  end
end

class ToybacoRedisRakeTest < Minitest::Test
  RAKE_FILE = File.expand_path('../overlay/app/lib/tasks/toybaco_redis.rake', __dir__)

  def setup
    return if Rake::Task.task_defined?('toybaco:redis_census')

    Rake::Task.define_task(:environment)
    load RAKE_FILE
  end

  def run_task(name, *args)
    task = Rake::Task[name]
    task.reenable
    status = nil
    out, err = capture_io do
      status = assert_raises(SystemExit) { task.invoke(*args) }.status
    end
    [status, out + err]
  end

  def test_census_prints_only_the_error_class_and_exits_1
    status, output = run_task('toybaco:redis_census')
    assert_equal 1, status
    assert_equal "TOYBACO_REDIS_CENSUS error class=Redis::SecretFailure\n", output
  end

  def test_reconcile_prints_only_the_error_class_and_exits_1
    status, output = run_task('toybaco:redis_reconcile', 'redis:toybaco-redis.abc123.0001.apne1.cache.amazonaws.com',
                              'rediss:master.toybaco-redis-enc.abc123.apne1.cache.amazonaws.com')
    assert_equal 1, status
    assert_equal "TOYBACO_REDIS_RECONCILE error class=Redis::SecretFailure\n", output
    %w[STATE-SECRET-1 abc123 GET alfred].each { |secret| refute_includes output, secret }
  end
end

# minitest の stub は module の定数を差し替えられないため、テストの間だけ定数を置き換える。
class Module
  def stub_const(name, value)
    original = const_get(name)
    silence = $VERBOSE
    $VERBOSE = nil
    const_set(name, value)
    yield
  ensure
    const_set(name, original)
    $VERBOSE = silence
  end
end
