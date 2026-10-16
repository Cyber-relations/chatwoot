# frozen_string_literal: true

require_relative 'redis_key_family'

# CLIENT LIST の種別の集計(暗号化切替の準備、2026-10-15)。toybaco:redis_census が使う。
# 接続中の client を (種別, DB, 最後の command, flags) で数える。種別は client の名前と DB から次の固定の語に写像し、名前の生値は出さない。
#   sidekiq: Sidekiq-* / actioncable: ActionCable-* / census: toybaco-redis-census / reconcile: toybaco-redis-reconcile /
#   chatwoot: 名前の無い DB 0 の接続(rails・sidekiq の $alfred・$velma)/ postiz: 名前の無い DB 1 の接続(ioredis)/
#   unnamed: 名前の無いそれ以外の DB / other: 名前のあるそれ以外
# 接続元の address・port・user は出さず、census 以外の接続元の異なる host の数だけを出す。fence(writer の停止)の後に、census 自身
# 以外の client が残っていないことを確かめるために使う。CLIENT が使えない Redis では unavailable の 1 行だけを出す(class 名だけ)。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    module RedisClientList
      FIELD = /\A([a-z-]+)=(.*)\z/
      NAMED_KINDS = [[/\ASidekiq-/, 'sidekiq'], [/\AActionCable-/, 'actioncable'], [/\Atoybaco-redis-census\z/, 'census'],
                     [/\Atoybaco-redis-reconcile\z/, 'reconcile']].freeze
      UNNAMED_KINDS = { '0' => 'chatwoot', '1' => 'postiz' }.freeze
      KINDS = %w[sidekiq actioncable census reconcile chatwoot postiz unnamed other].freeze

      module_function

      def lines(client, prefix)
        rows = parse(client.call('CLIENT', 'LIST'))
        groups = rows.group_by { |row| group(row) }.transform_values(&:length)
        [summary(prefix, rows)] +
          groups.sort.map { |(kind, db, cmd, flags), count| "#{prefix} client kind=#{kind} db=#{db} cmd=#{cmd} flags=#{flags} count=#{count}" }
      rescue StandardError => e
        ["#{prefix} clients unavailable=#{RedisKeyFamily.token(e.class.name)}"]
      end

      def summary(prefix, rows)
        others = rows.reject { |row| kind(row) == 'census' }
        hosts = others.map { |row| host(row['addr']) }.uniq.length
        "#{prefix} clients total=#{rows.length} others=#{others.length} distinct-hosts=#{hosts}"
      end

      def parse(text)
        text.to_s.each_line.map do |row|
          row.split.filter_map { |field| field.match(FIELD)&.captures }.to_h
        end
      end

      def group(row)
        [kind(row), RedisKeyFamily.token(row['db']), RedisKeyFamily.token(row['cmd'].to_s.tr('|', '.')), RedisKeyFamily.token(row['flags'])]
      end

      # 名前と DB から KINDS のどれか。名前の生値は返さない。
      def kind(row)
        name = row['name'].to_s
        return UNNAMED_KINDS.fetch(row['db'].to_s, 'unnamed') if name.empty?

        NAMED_KINDS.find { |pattern, _| name.match?(pattern) }&.last || 'other'
      end

      def host(addr)
        addr.to_s.rpartition(':').first
      end
    end
  end
end
