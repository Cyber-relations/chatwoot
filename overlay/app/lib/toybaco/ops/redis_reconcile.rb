# frozen_string_literal: true

require 'time'
require_relative 'redis_key_family'
require_relative 'redis_key_scan'
require_relative 'redis_value_digest'

# 切替前後の Redis の突合(暗号化切替の準備、2026-10-15)。toybaco:redis_reconcile(lib/tasks/toybaco_redis.rake)の本体。
# writer を止めた(fence)後の旧 Redis(source)と、最終 snapshot から復元した新 Redis(target)を読むだけで突き合わせる。
# 全 DB の全 key について、型・値の論理的な digest(RedisValueDigest)・絶対の期限(PEXPIRETIME、ミリ秒)を比べ、
# 系統(RedisKeyFamily)ごとに結果の件数だけを出す。key 名・値・digest・接続先の host は出さない。結果は次のどれか。
#   match: 型・値・期限が一致
#   expired: 片側だけにある key の期限が、その batch を読む前に両側の Redis の TIME で取った時刻の小さい方までに過ぎている
#     (読んでいる間に期限が来た key は expired にせず missing / extra にする。時計の差や読み取りの時間で一致にしない)
#   vanished: SCAN の後、両側の読み取りで無かった key。期限切れの証拠が無い消失として、失敗には数えず件数を出す
#   missing: source にあり target に無い(snapshot の後に増えた queue の job など)
#   extra: target にだけある(snapshot の後に消費した nonce・OAuth state が復元で戻った、または target への書き込み)
#   type-mismatch / value-mismatch / expiry-mismatch / too-large / unsupported(digest が無い・未知の結果も unsupported)
# missing 以下が 1 件でもあるか、SCAN を打ち切った DB があれば verdict=mismatch(切替を進めない)。
# 値を読む契約(RedisCommandGuard の reconcile profile): INFO・SCAN・TIME・TYPE・PEXPIRETIME と、RedisValueDigest の値の読み取り
# (GET・LLEN / LRANGE・SSCAN・ZCARD / ZRANGE・HSCAN・XLEN / XRANGE・XINFO GROUPS / CONSUMERS・XPENDING)だけを送る。値は process の
# 中で digest にして比べ、出さない。期限切れの key に TYPE・PEXPIRETIME・SCAN が触れると Redis はその key を遅延削除するが、
# 期限切れの key は論理的には既に無いので、読める状態は変わらない。
# 接続先の形・TLS の検証・出力に出す名前は RedisEndpoint に従う。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    module RedisReconcile
      PREFIX = 'TOYBACO_REDIS_RECONCILE'
      FAILURES = %w[missing extra type-mismatch value-mismatch expiry-mismatch too-large unsupported].freeze
      OUTCOMES = (%w[match expired vanished] + FAILURES).freeze
      BATCH = 200
      MAX_KEYS = 250_000

      module_function

      # source_for / target_for は DB 番号から client を作る。labels は RedisEndpoint.labels(source, target) の形。
      # 返り値は { lines:, match: }。比べる時刻は host の時計ではなく、両側の Redis の TIME を使う。
      def run(source_for:, target_for:, labels:)
        started = start_line(labels)
        counts = new_counts
        sizes = (RedisKeyScan.databases(source_for, :reconcile) | RedisKeyScan.databases(target_for, :reconcile) | [0, 1]).sort.map do |db|
          compare_database(db, [source_for, target_for], counts[db])
        end
        verdict = verdict(counts, sizes)
        { lines: [started] + sizes.map { |size| line('db', size) } + family_lines(counts) + [line('verdict', verdict)],
          match: verdict[:result] == 'match' }
      end

      # { db => { [名前空間, 系統] => { 結果 => 件数 } } }。
      def new_counts
        Hash.new { |by_db, db| by_db[db] = Hash.new { |by_family, family| by_family[family] = Hash.new(0) } }
      end

      def start_line(labels)
        line('start', { at: ::Time.now.utc.iso8601 }.merge(labels.slice(:source_tls, :target_tls, :source_id, :target_id)))
      end

      def verdict(counts, sizes)
        truncated = sizes.any? { |size| size[:truncated] }
        failures = total(counts, FAILURES)
        { result: !truncated && failures.zero? ? 'match' : 'mismatch', failures: failures, vanished: total(counts, %w[vanished]),
          truncated: truncated }
      end

      def total(counts, outcomes)
        counts.values.sum { |families| families.values.sum { |row| outcomes.sum { |outcome| row[outcome] } } }
      end

      def compare_database(db, (source_for, target_for), rows)
        RedisKeyScan.with_client(source_for, db, :reconcile) do |source|
          RedisKeyScan.with_client(target_for, db, :reconcile) do |target|
            source_keys, source_cut = RedisKeyScan.scan(source, max_keys: MAX_KEYS)
            target_keys, target_cut = RedisKeyScan.scan(target, max_keys: MAX_KEYS)
            (source_keys | target_keys).each_slice(BATCH) do |batch|
              # 読む前の時刻(両側の TIME の小さい方)。これより前に期限が来た key だけを expired にする。
              before = [RedisKeyScan.server_time_ms(source), RedisKeyScan.server_time_ms(target)].min
              tally(rows, batch, [read(source, batch), read(target, batch)], before)
            end
            { db: db, source_keys: source_keys.length, target_keys: target_keys.length, truncated: source_cut || target_cut }
          end
        end
      end

      def tally(rows, batch, (sources, targets), before)
        batch.each_with_index do |key, index|
          type = (sources[index] || targets[index])&.fetch(:type)
          rows[RedisKeyFamily.classify(key, type)][outcome(sources[index], targets[index], before)] += 1
        end
      end

      # key ごとの { type:, expire:, digest: }。無い key は nil。pipelined は redis-rb 5.0.6 の形(引数なし)で、PEXPIRETIME の無い
      # Redis(7.0 未満)では command の error を raise して止まる。
      def read(client, batch)
        replies = client.pipelined do |pipe|
          batch.each do |key|
            pipe.call('TYPE', key)
            pipe.call('PEXPIRETIME', key)
          end
        end
        batch.each_with_index.map do |key, index|
          type = replies[index * 2].to_s
          expire = replies[(index * 2) + 1]
          RedisKeyScan.integer!(expire)
          next nil if type == 'none' || expire == -2

          { type: type, expire: expire, digest: RedisValueDigest.digest(client, key, type) }
        end
      end

      # before は読む前の時刻(ミリ秒)。
      def outcome(source, target, before)
        return one_sided(source, target, before) if source.nil? || target.nil?
        return 'type-mismatch' unless source[:type] == target[:type]

        compare(source, target)
      end

      # 片側にしか無い key。ある側の期限が読む前の時刻までに過ぎていれば expired(読んでいる間に来た期限は数えない)。
      # 両側に無ければ vanished(期限切れの証拠が無い消失)。
      def one_sided(source, target, before)
        side = source || target
        return 'vanished' if side.nil?
        return 'expired' if side[:expire].positive? && side[:expire] <= before

        source ? 'missing' : 'extra'
      end

      # digest は RedisValueDigest が String(16 進)か Symbol(:too_large / :unsupported)で返す。nil や未知の Symbol は
      # 比べられないので unsupported(失敗)にする(nil 同士を一致にしない)。
      def compare(source, target)
        problem = digest_problem([source[:digest], target[:digest]])
        return problem if problem
        return 'value-mismatch' unless source[:digest] == target[:digest]

        source[:expire] == target[:expire] ? 'match' : 'expiry-mismatch'
      end

      # 比べられない digest の結果(失敗の名前)。比べられれば nil。
      def digest_problem(digests)
        return 'unsupported' unless digests.all? { |digest| digest.is_a?(String) || digest.is_a?(Symbol) }

        symbol = digests.find { |digest| digest.is_a?(Symbol) }
        return nil unless symbol

        name = symbol.to_s.tr('_', '-')
        FAILURES.include?(name) ? name : 'unsupported'
      end

      # 出せない系統は DB・名前空間ごとの opaque に合算する。
      def family_lines(counts)
        counts.sort.flat_map do |db, families|
          RedisKeyFamily.collapse(families, OUTCOMES)
                        .map { |name, outcomes| line('family', { db: db, name: name }.merge(outcomes)) }
        end
      end

      def line(kind, fields)
        RedisKeyScan.line(PREFIX, kind, fields)
      end
    end
  end
end
