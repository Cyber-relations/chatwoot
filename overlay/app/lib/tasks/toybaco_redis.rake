# frozen_string_literal: true

# Redis(ElastiCache)の暗号化切替の準備(2026-10-15、docs/growth-release-20260918/redis-encryption-cutover-plan-20261015.md)。
# どちらのタスクも Redis を読むだけで、key・値・期限を書き換えない(監査行 started / ok|failed は toybaco_ops.rake の RakeAudit が
# 別の DB セッションで書く)。期限切れの key に TYPE・PTTL・PEXPIRETIME・SCAN が触れると Redis はその key を遅延削除するが、
# 期限切れの key は論理的には既に無いので、読める状態は変わらない。key 名・値・接続元の address・接続先の host は出さず、件数と種別だけを 1 行 1 事実の key=value で出す。
# - toybaco:redis_census: 稼働中の設定(Redis::Config.app = REDIS_URL と TLS の設定)のまま、DB ごとの件数・系統ごとの件数と
#   TTL の分布・接続中の client の種別を出す。ops-rake の allowlist に入れ、両環境で使う(引数なし)。
# - toybaco:redis_reconcile[source,target]: fence の後の旧 Redis と、最終 snapshot から復元した新 Redis を突き合わせる。
#   引数は <redis|rediss>:<ElastiCache の host> を 2 つ。不一致なら abort する(切替を進めない)。新しい group の endpoint は
#   切替の当日まで無いため、ops-rake の allowlist には切替の PR で入れる(計画書の「切替の手順」の 0. と 2.)。
# Redis の例外の文には command と key 名が入り得る(ops-rake の Step Summary と job log に残る)。どちらのタスクも例外を握り、
# 「<PREFIX> error class=<例外の class 名>」の 1 行だけを出して exit 1 にする(監査行は failed になる)。
# rake は Rails の初期化前にこのファイルを読むため、本体は lib の入れ子のモジュールに置き、Redis の定数は実行時に参照する。
require_relative '../toybaco/ops/redis_endpoint'
require_relative '../toybaco/ops/redis_census'
require_relative '../toybaco/ops/redis_reconcile'

namespace :toybaco do
  desc 'Redis の DB 別・系統別の key 件数、TTL の分布、接続中の client の種別を読み取りだけで表示する(key 名・値は出さない)'
  task redis_census: :environment do
    census = Toybaco::Ops::RedisCensus
    lines, ok = Toybaco::Ops::RedisKeyScan.guard_errors(census::PREFIX) { census.run(Redis::Config.app) }
    lines.each { |line| puts line }
    exit 1 unless ok
  end

  desc 'fence の後の旧 Redis と復元した新 Redis を読み取りだけで突き合わせる' \
       '(rake "toybaco:redis_reconcile[<redis|rediss>:<旧の host>,<redis|rediss>:<新の host>]")'
  task :redis_reconcile, %i[source target] => :environment do |_t, args|
    abort '引数は旧と新の接続先の 2 つだけを指定してください。' unless args.extras.empty?

    reconcile = Toybaco::Ops::RedisReconcile
    endpoint = Toybaco::Ops::RedisEndpoint
    begin
      source = endpoint.parse(args[:source])
      target = endpoint.parse(args[:target])
    rescue ArgumentError => e
      abort e.message
    end
    client_for = ->(parsed) { ->(db) { Redis.new(endpoint.options(parsed, db).merge(id: 'toybaco-redis-reconcile')) } }
    result, ok = Toybaco::Ops::RedisKeyScan.guard_errors(reconcile::PREFIX) do
      reconcile.run(source_for: client_for.call(source), target_for: client_for.call(target), labels: endpoint.labels(source, target))
    end
    (ok ? result.fetch(:lines) : result).each { |line| puts line }
    exit 1 unless ok
    abort "#{reconcile::PREFIX} 突合が一致しませんでした。切替を進めずに計画書の rollback に従ってください。" unless result.fetch(:match)
  end
end
