# frozen_string_literal: true

require 'openssl'
require 'time'
require 'uri'
require_relative 'redis_endpoint'
require_relative 'redis_key_family'
require_relative 'redis_key_scan'
require_relative 'redis_client_list'

# Redis の writer の棚卸し(暗号化切替の準備、2026-10-15)。toybaco:redis_census(lib/tasks/toybaco_redis.rake)の本体。
# metadata だけを読む(RedisCommandGuard の census profile): INFO・CLIENT LIST・SCAN・TYPE・PTTL・要素数(LLEN / SCARD / ZCARD /
# HLEN / XLEN)しか送らず、値は読まない。Sidekiq の process の key は key の形と TYPE(hash)で見分ける(SMEMBERS は送らない)。
# 接続の確立時に redis-client が送る CLIENT SETNAME(toybaco-redis-census)などは wrapper の外。期限切れの key に TYPE・PTTL・SCAN が触れると Redis はその key を
# 遅延削除するが、期限切れの key は論理的には既に無いので、読める状態は変わらない(rdb_changes_since_last_save と expired_keys が
# 同じだけ増えるので、fence の確認の差し引きにも影響しない)。key 名・値・接続元の address は出さない。DB ごとの件数(INFO keyspace と SCAN の件数)、
# 系統(RedisKeyFamily)ごとの件数・型・要素数・TTL の分布、接続中の client の種別(RedisClientList)を 1 行 1 事実の key=value
# (TOYBACO_REDIS_CENSUS で始まる)で返す。SCAN は DB ごとに MAX_KEYS 件か、全体で MAX_SECONDS 秒で打ち切り、打ち切ったら
# truncated=true を出す(件数を全数と読み違えないため)。rake は Rails の初期化前にこのファイルを読むため、モジュールは入れ子で
# 定義し、読み込みの時点では標準ライブラリ以外を参照しない(redis-rb の Redis は run の実行時にだけ参照する)。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    module RedisCensus
      PREFIX = 'TOYBACO_REDIS_CENSUS'
      BATCH = 500
      MAX_KEYS = 250_000
      MAX_SECONDS = 300
      TYPES = %w[string list set zset hash stream].freeze
      # PTTL(ミリ秒)の上限と列名。-1 は ttl-none、-2(SCAN の後に消えた)は vanished に数える。
      TTL_BUCKETS = [[60_000, 'ttl-le-1m'], [3_600_000, 'ttl-le-1h'], [86_400_000, 'ttl-le-1d'], [604_800_000, 'ttl-le-7d'],
                     [2_592_000_000, 'ttl-le-30d']].freeze
      TTL_COLUMNS = (['ttl-none'] + TTL_BUCKETS.map(&:last) + ['ttl-gt-30d']).freeze
      COLUMNS = (['keys'] + TYPES + %w[other-type vanished items] + TTL_COLUMNS).freeze
      # persistence の rdb_changes_since_last_save は最後の保存以降の書き込み(期限切れの削除を含む)の数。fence の後に 2 回 census を
      # 取り、その増分が expired_keys の増分を超えなければ、書く client は残っていない(計画書の fence の確認)。
      INFO_SECTIONS = %w[server replication memory clients persistence stats].freeze
      # server 行の列と INFO の項目名(出力の順)。
      SERVER_FIELDS = { version: 'redis_version', role: 'role', used_memory: 'used_memory', maxmemory: 'maxmemory',
                        maxmemory_policy: 'maxmemory_policy', connected_clients: 'connected_clients', blocked_clients: 'blocked_clients',
                        changes_since_save: 'rdb_changes_since_last_save', expired_keys: 'expired_keys',
                        evicted_keys: 'evicted_keys' }.freeze

      module_function

      # toybaco:redis_census の本体。稼働中の設定(Redis::Config.app)のまま DB ごとに繋ぐ(url の DB は db: で上書きする)。
      def run(config)
        client_for = ->(db) { ::Redis.new(config.merge(db: db, reconnect_attempts: 0, timeout: 5, id: 'toybaco-redis-census')) }
        lines(client_for: client_for, connection: connection(config))
      end

      # 稼働中の設定(Redis::Config.app の url と ssl_params)から、出力に出す接続の種別を作る。host そのものは出さない。
      # ops-rake は migrate の revision を image と TOYBACO_ の環境変数で選び、REDIS_URL を比べないため、切替の前後では
      # target(接続先の ElastiCache の名前)と tls で、どちらの Redis を読んだかを確かめる。
      def connection(config)
        uri = ::URI.parse(config.fetch(:url).to_s)
        tls = uri.scheme == 'rediss'
        verify = config.dig(:ssl_params, :verify_mode) == ::OpenSSL::SSL::VERIFY_NONE ? 'none' : 'peer'
        { tls: tls ? 'on' : 'off', verify: tls ? verify : 'na', target: RedisEndpoint.label(uri.host) }
      end

      # connection は connection(config) の形。返り値は出力の行の配列。
      def lines(client_for:, connection:, clock: -> { ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) })
        started = clock.call
        stop = -> { clock.call - started > MAX_SECONDS }
        output = [start_line(connection)]
        keyspace = RedisKeyScan.with_client(client_for, 0, :census) { |client| server_lines(client, output) }
        databases = ([0, 1] + keyspace.keys).uniq.sort
        databases.each { |db| output.concat(scan_database(client_for, db, keyspace[db], stop)) }
        output << line('done', result: 'ok', databases: databases.length, elapsed_ms: ((clock.call - started) * 1000).round)
      end

      def start_line(connection)
        line('start', { at: ::Time.now.utc.iso8601 }.merge(connection.slice(:tls, :verify, :target)))
      end

      def scan_database(client_for, db, keyspace_row, stop)
        RedisKeyScan.with_client(client_for, db, :census) { |client| database_lines(client, db, keyspace_row, stop) }
      end

      # INFO と CLIENT LIST(DB 0 の接続で 1 回)。返り値は INFO keyspace の { db => [keys, expires] }。
      def server_lines(client, output)
        info = INFO_SECTIONS.sum('') { |section| client.call('INFO', section).to_s }.each_line.filter_map do |row|
          row.strip.split(':', 2) if row.include?(':') && !row.start_with?('#')
        end.to_h
        output << line('server', SERVER_FIELDS.transform_values { |name| info[name] })
        output.concat(RedisClientList.lines(client, PREFIX))
        RedisKeyScan.keyspace(client.call('INFO', 'keyspace'))
      end

      def database_lines(client, db, keyspace_row, stop)
        keys, truncated = RedisKeyScan.scan(client, max_keys: MAX_KEYS, stop: stop)
        families = Hash.new { |hash, family| hash[family] = RedisKeyScan.zero_row(COLUMNS) }
        keys.each_slice(BATCH) { |batch| tally(client, batch, families) }
        rows = RedisKeyFamily.collapse(families, COLUMNS)
        info_keys, info_expires = keyspace_row || [0, 0]
        [line('db', db: db, keys_info: info_keys, expires_info: info_expires, scanned: keys.length, truncated: truncated,
                    families: rows.length)] +
          rows.map { |name, counts| line('family', { db: db, name: name }.merge(counts)) }
      end

      # pipelined は Chatwoot の redis-rb 5.0.6 の形(引数なし。応答に error があれば全 command を読んだ後に最初の error を raise)。
      def tally(client, batch, families)
        replies = client.pipelined do |pipe|
          batch.each do |key|
            pipe.call('TYPE', key)
            pipe.call('PTTL', key)
          end
        end
        types = batch.each_with_index.map { |key, index| [key, replies[index * 2].to_s, RedisKeyScan.integer!(replies[(index * 2) + 1])] }
        sizes = RedisKeyScan.sizes(client, types)
        types.each_with_index do |(key, type, ttl), index|
          count_key(families[RedisKeyFamily.classify(key, type)], type, ttl, sizes.fetch(index, 0))
        end
      end

      def count_key(counts, type, ttl, size)
        return counts['vanished'] += 1 if type == 'none' || ttl == -2

        counts['keys'] += 1
        counts[TYPES.include?(type) ? type : 'other-type'] += 1
        counts['items'] += size
        counts[ttl_column(ttl)] += 1
      end

      def ttl_column(ttl)
        return 'ttl-none' if ttl.negative?

        TTL_BUCKETS.find { |limit, _| ttl <= limit }&.last || 'ttl-gt-30d'
      end

      def line(kind, fields)
        RedisKeyScan.line(PREFIX, kind, fields)
      end
    end
  end
end
