# frozen_string_literal: true

require 'digest'

# 1 つの key の値の論理的な digest(暗号化切替の準備、2026-10-15)。toybaco:redis_reconcile が切替前後の Redis を突き合わせるために使う。
# 読むだけ: GET・LLEN / LRANGE・SSCAN・ZCARD / ZRANGE・HSCAN・XLEN / XRANGE・XINFO GROUPS / CONSUMERS・XPENDING しか送らない
# (RedisCommandGuard の reconcile profile)。digest はこの process の中で
# 比べるだけで出さない(値・key 名も出さない)。RDB の複製は符号化(listpack / quicklist など)が変わり得るため DUMP は比べず、
# 型ごとの論理の値(list は順、zset は score の順、set と hash は並べ替えた順)を比べる。stream は entry に加え、consumer group ごとの
# 名前・未処理の数・最後に配った ID、未処理の entry(XPENDING の ID・consumer・配った回数。idle 時間は比べない)、consumer の名前を含める。
# 要素が MAX_ELEMENTS を超える key と、未処理が MAX_PENDING を超える group を持つ stream は :too_large、未知の型は :unsupported を返す
# (どちらも突合の失敗として数える)。
# RESP2 と RESP3 のどちらの応答も同じ digest になるよう、zset の score は 17 桁の浮動小数点の表現にそろえる。
# 値は長さ付きで符号化し、stream は件数・各 entry の field の数・group と未処理の件数も入れて構造を保つ(entry の境目が違えば別の値)。
# 入れ子の名前空間では Digest が Toybaco::Ops::Digest(運営ダイジェスト)に解決されるため、標準ライブラリは ::Digest のように明示する。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    module RedisValueDigest
      CHUNK = 1000
      MAX_ELEMENTS = 1_000_000
      MAX_PENDING = 10_000
      GROUP_FIELDS = %w[name pending last-delivered-id].freeze
      # 型ごとの読み手。Module 自身のメソッド(hash など)と名前が重ならないよう read_ を付ける。
      READERS = { 'string' => :read_string, 'list' => :read_list, 'set' => :read_set, 'zset' => :read_zset, 'hash' => :read_hash,
                  'stream' => :read_stream }.freeze

      module_function

      # 返り値は String(16 進の digest)か Symbol(:too_large / :unsupported)で、nil は返さない。TYPE の後に消えた key は空の値として
      # digest になる(突合の側で期限と型を別に比べる)。
      def digest(client, key, type)
        reader = READERS[type]
        return :unsupported unless reader

        sha = ::Digest::SHA256.new
        result = public_send(reader, client, key, sha)
        result.is_a?(Symbol) ? result : sha.hexdigest
      end

      def add(sha, values)
        values.each do |value|
          bytes = value.nil? ? "\0nil" : value.to_s.b
          sha << "#{bytes.bytesize}:" << bytes
        end
        sha
      end

      def read_string(client, key, sha)
        add(sha, [client.call('GET', key)])
      end

      def read_list(client, key, sha)
        length = client.call('LLEN', key).to_i
        return :too_large if length > MAX_ELEMENTS

        (0...length).step(CHUNK) { |start| add(sha, client.call('LRANGE', key, start, start + CHUNK - 1)) }
        sha
      end

      def read_set(client, key, sha)
        members = scan_all(client, 'SSCAN', key)
        members.is_a?(Symbol) ? members : add(sha, members.uniq.sort)
      end

      def read_hash(client, key, sha)
        pairs = scan_all(client, 'HSCAN', key)
        pairs.is_a?(Symbol) ? pairs : add(sha, pairs.each_slice(2).to_h.sort.flatten)
      end

      def read_zset(client, key, sha)
        length = client.call('ZCARD', key).to_i
        return :too_large if length > MAX_ELEMENTS

        (0...length).step(CHUNK) do |start|
          reply = client.call('ZRANGE', key, start, start + CHUNK - 1, 'WITHSCORES')
          pairs = reply.first.is_a?(Array) ? reply : reply.each_slice(2).to_a
          add(sha, pairs.flat_map { |member, score| [member, format('%.17g', Float(score))] })
        end
        sha
      end

      def read_stream(client, key, sha)
        length = Integer(client.call('XLEN', key))
        return :too_large if length > MAX_ELEMENTS

        add(sha, ['stream', length])
        last = '-'
        loop do
          entries = client.call('XRANGE', key, last, '+', 'COUNT', CHUNK)
          entries.each { |id, fields| add_entry(sha, id, fields) }
          break if entries.length < CHUNK

          last = "(#{entries.last.first}"
        end
        stream_groups(client, key, sha)
      end

      # 1 つの entry を ID・field と値の数・field と値の順に足す(entry の境目を保つ)。
      def add_entry(sha, id, fields)
        values = Array(fields).flatten
        add(sha, ['entry', id, values.length] + values)
      end

      # SSCAN / HSCAN の全要素(重複を含み得る)。hash は field と値の 2 要素ずつなので上限を 2 倍にする。
      def scan_all(client, command, key)
        values = []
        cursor = '0'
        loop do
          cursor, batch = client.call(command, key, cursor, 'COUNT', CHUNK)
          values.concat(batch)
          return :too_large if values.length > MAX_ELEMENTS * 2
          return values if cursor.to_s == '0'
        end
      end

      # consumer group を名前の順に、名前・未処理の数・最後に配った ID、consumer の名前、未処理の entry の ID・consumer・配った回数。
      def stream_groups(client, key, sha)
        groups = client.call('XINFO', 'GROUPS', key).map { |group| fields(group) }.sort_by { |group| group['name'].to_s }
        add(sha, ['groups', groups.length])
        groups.each { |group| return :too_large if add_group(client, key, group, sha) == :too_large }
        sha
      end

      # 1 つの group を sha に足す。未処理が MAX_PENDING を超えれば :too_large。
      def add_group(client, key, group, sha)
        pending = Integer(group['pending'])
        return :too_large if pending > MAX_PENDING

        add(sha, ['group'] + GROUP_FIELDS.map { |field| group[field] })
        consumers = client.call('XINFO', 'CONSUMERS', key, group['name']).map { |consumer| fields(consumer)['name'] }.sort
        add(sha, ['consumers', consumers.length] + consumers)
        entries = pending_entries(client, key, group['name'], pending)
        add(sha, ['pending', entries.length])
        entries.each { |id, consumer, _idle, deliveries| add(sha, ['pending-entry', id, consumer, deliveries]) }
        nil
      end

      def pending_entries(client, key, group, pending)
        pending.zero? ? [] : client.call('XPENDING', key, group, '-', '+', pending)
      end

      # RESP3 の map(Hash)と RESP2 の field と値の並び(Array)をそろえる。
      def fields(reply)
        reply.is_a?(Hash) ? reply : reply.each_slice(2).to_h
      end
    end
  end
end
