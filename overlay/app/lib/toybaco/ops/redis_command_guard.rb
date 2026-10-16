# frozen_string_literal: true

# toybaco:redis_census / toybaco:redis_reconcile が Redis に送ってよい command の allowlist(暗号化切替の準備、2026-10-15)。
# client_for が作った生の client をこの wrapper で包み、call / pipelined / close だけを渡す。allowlist に無い command は送る前に
# Refused を raise する(書き込みの command を通さない)。profile は 2 つ。
#   census: metadata だけ。INFO・CLIENT LIST・SCAN・TYPE・PTTL・要素数(LLEN / SCARD / ZCARD / HLEN / XLEN)。値は読まない
#   reconcile: 値を読む別の契約。INFO・SCAN・TIME・TYPE・PEXPIRETIME と、値の digest のための GET・LLEN / LRANGE・SSCAN・
#     ZCARD / ZRANGE・HSCAN・XLEN / XRANGE・XINFO GROUPS / CONSUMERS・XPENDING
# 接続の確立時に redis-client が送る HELLO・AUTH・SELECT・CLIENT SETNAME(client の名前)はこの wrapper の外にある。
# rake は Rails の初期化前にこのファイルを読むため、モジュールは入れ子で定義し、標準ライブラリ以外を参照しない。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    module RedisCommandGuard
      PROFILES = {
        census: %w[INFO CLIENT SCAN TYPE PTTL LLEN SCARD ZCARD HLEN XLEN].freeze,
        reconcile: %w[INFO SCAN TIME TYPE PEXPIRETIME GET LLEN LRANGE SSCAN ZCARD ZRANGE HSCAN XLEN XRANGE XINFO XPENDING].freeze
      }.freeze
      # subcommand を持つ command は、読み取りの subcommand だけを許す。
      SUBCOMMANDS = { 'CLIENT' => %w[LIST], 'XINFO' => %w[GROUPS CONSUMERS] }.freeze

      # 許されない command。command の名前だけを文に入れ、引数(key 名)は入れない。
      Refused = Class.new(::StandardError)

      module_function

      def wrap(client, profile)
        Client.new(client, profile)
      end

      # 送る command。名前(と subcommand)は String の新しい複製を大文字にしたもので、判定にも送信にもこの値を使う
      # (to_s や upcase を偽る String の派生や、判定の後に中身が変わる object を client に渡さない)。
      def normalize!(profile, command)
        allowed = PROFILES.fetch(profile)
        name = plain(command.first)
        rest = command.drop(1)
        subcommands = SUBCOMMANDS[name]
        rest = [plain(rest.first)] + rest.drop(1) if subcommands
        unless allowed.include?(name) && (subcommands.nil? || subcommands.include?(rest.first))
          raise Refused, "Redis の command #{name[/\A[A-Z]{1,20}\z/] || 'other'} はこの用途では送れません"
        end

        [name] + rest
      end

      def plain(value)
        ::String.new(value.is_a?(::String) ? value : value.to_s).upcase
      end

      # call / pipelined / close だけを持つ。profile(PROFILES の key)からしか作れず、送れる command の一覧を外から渡せない。
      # pipelined の中の pipe も同じ class で包む(pipe には call だけを使う)。
      class Client
        def initialize(client, profile)
          raise ::ArgumentError, 'Redis の command の profile は census か reconcile だけです' unless PROFILES.key?(profile)

          @client = client
          @profile = profile
        end

        def call(*command)
          @client.call(*RedisCommandGuard.normalize!(@profile, command))
        end

        def pipelined
          @client.pipelined { |pipe| yield Client.new(pipe, @profile) }
        end

        def close
          @client.close
        end
      end
    end
  end
end
