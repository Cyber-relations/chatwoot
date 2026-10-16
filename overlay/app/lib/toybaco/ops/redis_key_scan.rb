# frozen_string_literal: true

require_relative 'redis_command_guard'
require_relative 'redis_key_family'

# toybaco:redis_census と toybaco:redis_reconcile に共通の読み取りと出力の整形(暗号化切替の準備、2026-10-15)。
# client は client_for.(db) で DB ごとに作り、RedisCommandGuard の profile(census / reconcile)で包んでから渡し、使い終えたら閉じる。
# 送る command は profile の allowlist に限る(このファイルが使うのは SCAN・INFO・TIME と要素数の LLEN / SCARD / ZCARD / HLEN / XLEN)。
# 出力の行は「PREFIX 種類 key=value ...」で、key の _ は - にし、値は整数・真偽値か RedisKeyFamily.token を通したものだけにする。
# rake は Rails の初期化前にこのファイルを読むため、モジュールは入れ子で定義し、標準ライブラリ以外を参照しない。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    module RedisKeyScan
      SCAN_COUNT = 1000
      SIZE_COMMANDS = { 'list' => 'LLEN', 'set' => 'SCARD', 'zset' => 'ZCARD', 'hash' => 'HLEN', 'stream' => 'XLEN' }.freeze
      KEYSPACE_LINE = /\Adb(\d{1,2}):keys=(\d+),expires=(\d+)/

      # 整数のはずの応答が整数でない(空の key と失敗を同じ 0 にしない)。応答の値は文に入れない。
      class UnexpectedReply < StandardError; end

      module_function

      def with_client(client_for, db, profile)
        client = client_for.call(db)
        yield RedisCommandGuard.wrap(client, profile)
      ensure
        client&.close
      end

      # [key の配列, 打ち切ったか]。SCAN は同じ key を返し得るので重ねない。cursor が 0 に戻り、key が max_keys 件以下なら完了。
      # max_keys 件を超えたか、cursor が残ったまま max_keys 件に達したか、stop.() が真になったら打ち切る。
      def scan(client, max_keys:, stop: -> { false })
        seen = {}
        cursor = '0'
        loop do
          cursor, batch = client.call('SCAN', cursor, 'COUNT', SCAN_COUNT)
          batch.each { |key| seen[key] = true }
          done = cursor.to_s == '0'
          return [seen.keys, false] if done && seen.length <= max_keys
          return [seen.keys.first(max_keys), true] if done || seen.length >= max_keys || stop.call
        end
      end

      # Redis の TIME(秒とマイクロ秒)をミリ秒にする。突合の期限の比べは host の時計ではなくこれを使う。
      def server_time_ms(client)
        seconds, micros = client.call('TIME')
        (Integer(seconds) * 1000) + (Integer(micros) / 1000)
      end

      # key のある DB の番号(DB 0 の接続の INFO keyspace)。
      def databases(client_for, profile)
        with_client(client_for, 0, profile) { |client| keyspace(client.call('INFO', 'keyspace')).keys }
      end

      # INFO keyspace の { db => [keys, expires] }。
      def keyspace(text)
        text.to_s.each_line.filter_map { |row| row.strip.match(KEYSPACE_LINE) }.to_h { |m| [m[1].to_i, [m[2].to_i, m[3].to_i]] }
      end

      def line(prefix, kind, fields)
        ([prefix, kind] + fields.map { |key, value| "#{key.to_s.tr('_', '-')}=#{value_token(value)}" }).join(' ')
      end

      def value_token(value)
        value.is_a?(Integer) || value == true || value == false ? value.to_s : RedisKeyFamily.token(value&.to_s)
      end

      # rake が例外で止まる時の 1 行。例外の文(redis-client は command と key 名を入れ得る)は出さず、class の名前だけを出す。
      def failure_line(prefix, error)
        line(prefix, 'error', class: error.class.name)
      end

      # rake の本体を包む。返り値は [本体の返り値, true] か、例外なら [[failure_line], false](rake が出力して exit 1 にする)。
      def guard_errors(prefix)
        [yield, true]
      rescue StandardError => e
        [[failure_line(prefix, e)], false]
      end

      # [key, 型, ...] の配列の要素数を { 配列の index => 要素数 } で返す(要素数の command がある型だけ)。
      # TYPE の後に型が変わった key は要素数の command が WRONGTYPE になる。その batch だけ 1 件ずつ読み直し、WRONGTYPE の key だけを
      # 0 として数える(読むだけなので再試行しない)。それ以外の error(LOADING・NOAUTH・NOPERM・BUSY・接続など)は止める。
      def sizes(client, typed_keys)
        sized = typed_keys.each_index.select { |index| SIZE_COMMANDS.key?(typed_keys[index][1]) }
        return {} if sized.empty?

        commands = sized.map { |index| [SIZE_COMMANDS.fetch(typed_keys[index][1]), typed_keys[index][0]] }
        sized.zip(read_sizes(client, commands)).to_h { |index, size| [index, integer!(size)] }
      end

      def read_sizes(client, commands)
        client.pipelined { |pipe| commands.each { |command| pipe.call(*command) } }
      rescue StandardError => e
        raise unless wrongtype_error?(e)

        commands.map { |command| single_size(client, command) }
      end

      def single_size(client, command)
        client.call(*command)
      rescue StandardError => e
        raise unless wrongtype_error?(e)

        0
      end

      # TYPE の後に型が変わった key の error(redis-rb の Redis::WrongTypeError / redis-client の RedisClient::WrongTypeError、
      # または WRONGTYPE で始まる error)だけ。rake は Redis の定数を読み込み前に参照できないため名前で見る。
      def wrongtype_error?(error)
        error.class.ancestors.any? { |ancestor| ancestor.name.to_s.end_with?('WrongTypeError') } ||
          error.message.to_s.start_with?('WRONGTYPE')
      end

      # 整数の応答だけを通す。それ以外は UnexpectedReply(fail closed)。
      def integer!(value)
        raise UnexpectedReply, 'Redis の応答が整数ではありません' unless value.is_a?(Integer)

        value
      end

      # 列ごとに 0 を入れた行(ActiveSupport の index_with を使わずに作る。rake は Rails の初期化前に読むため)。
      def zero_row(columns)
        columns.zip(Array.new(columns.length, 0)).to_h
      end
    end
  end
end
