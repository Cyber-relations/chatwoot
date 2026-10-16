# frozen_string_literal: true

require 'openssl'

# Redis の接続先の形と、出力に出してよい接続先の名前(暗号化切替の準備、2026-10-15)。
# toybaco:redis_census と toybaco:redis_reconcile(lib/tasks/toybaco_redis.rake)が共有する。
# 出力には host を出さず、ElastiCache の名前(cluster id か replication group id)だけを出す(account ごとの識別子・region は出さない)。
# 突合の接続先は <redis|rediss>:<host> の形で、host は ElastiCache の名前(REQUIRED_SUFFIX で終わる)に限り、port は 6379 に固定する。
# TLS の接続は VERIFY_PEER(既定の信頼先と hostname の検証)に固定し、REDIS_OPENSSL_VERIFY_MODE などの設定に従わない。
# rake は Rails の初期化前にこのファイルを読むため、モジュールは入れ子で定義し、標準ライブラリ以外を参照しない。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    module RedisEndpoint
      PORT = 6379
      REQUIRED_SUFFIX = '.cache.amazonaws.com'
      PATTERN = /\A(rediss?):([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+)\z/
      # replication group の endpoint の先頭の語(master.<group>... / replica.<group>...)。2 つ目の語が group の名前。
      ROLE_LABELS = %w[master replica].freeze
      LABEL = /\A[a-z][a-z0-9-]{0,39}\z/

      module_function

      # { scheme:, host: }。形が合わなければ ArgumentError(引数の値は文に入れない)。
      def parse(raw, required_suffix: REQUIRED_SUFFIX)
        match = raw.to_s.match(PATTERN)
        unless match && match[2].length <= 253 && (required_suffix.nil? || match[2].end_with?(required_suffix))
          raise ArgumentError, "接続先は <redis|rediss>:<host> の形で、host は #{required_suffix || '名前'} で終わる名前にしてください"
        end

        { scheme: match[1], host: match[2] }
      end

      # redis-rb(Redis.new)と redis-client(RedisClient.config)に共通の接続の設定。
      def options(endpoint, db)
        base = { host: endpoint.fetch(:host), port: PORT, db: db, timeout: 5, reconnect_attempts: 0 }
        return base unless endpoint.fetch(:scheme) == 'rediss'

        base.merge(ssl: true, ssl_params: { verify_mode: ::OpenSSL::SSL::VERIFY_PEER })
      end

      # 接続先の ElastiCache の名前だけ。ElastiCache の名前でなければ other。
      def label(host)
        host = host.to_s.downcase
        return 'other' unless host.end_with?(REQUIRED_SUFFIX)

        labels = host.split('.')
        name = ROLE_LABELS.include?(labels.first) ? labels[1] : labels.first
        name.to_s.match?(LABEL) ? name : 'other'
      end

      # 突合の start 行に出す、旧(source)と新(target)の TLS の on / off と ElastiCache の名前。
      def labels(source, target)
        { source_tls: source.fetch(:scheme) == 'rediss' ? 'on' : 'off', target_tls: target.fetch(:scheme) == 'rediss' ? 'on' : 'off',
          source_id: label(source.fetch(:host)), target_id: label(target.fetch(:host)) }
      end
    end
  end
end
