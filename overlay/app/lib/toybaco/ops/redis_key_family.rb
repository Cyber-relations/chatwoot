# frozen_string_literal: true

# Redis の key を系統(family)に分ける規則と、出力の値の整形(暗号化切替の準備、2026-10-15)。
# toybaco:redis_census と toybaco:redis_reconcile(lib/tasks/toybaco_redis.rake)が共有する。
# key 名には OAuth の state・MFA の nonce・メールアドレス(Rack::Attack の throttle)・token が入るため、key 名そのものは出さない。
# 出すのは「名前空間(alfred / velma / none の固定の語)+ 系統」だけで、系統はコードで定義した既知の語彙(KNOWN_FAMILIES)に限る。
# 語彙は Chatwoot・Sidekiq・sidekiq-cron・Toybaco の overlay・Postiz の source から棚卸しした先頭の語、Chatwoot の sidekiq.yml の
# queue 名(KNOWN_QUEUES。それ以外の queue は queue.other)、形と型で決める系統(Sidekiq の process は <host>:<pid>:<12 桁の 16 進> の
# hash、metrics、Rack::Attack、Postiz の throttler)。未知の語は件数や文字の種類に関わらず opaque にまとめる。
# 値は 64 字以内の英数字と . : - だけにし、_ は - にする(ops-rake の Step Summary のマスクが a_b 形の語を <id> にするため。
# toybaco:renewal_attention と同じ)。
# rake は Rails の初期化前にこのファイルを読むため、モジュールは入れ子で定義し、標準ライブラリ以外を参照しない。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    module RedisKeyFamily
      NAMESPACES = %w[alfred velma].freeze
      OPAQUE = 'opaque'
      NONE = 'none'
      TOKEN_FORMAT = /\A[A-Za-z0-9_.:-]{1,64}\z/
      # 2 つ目の語まで系統に含める先頭の語(GlobalConfig の V1:GLOBAL_CONFIG、toybaco:admin_mfa など)。
      TWO_LEVEL = /\A(?:V\d{1,2}|toybaco)\z/
      # Sidekiq 7 の process の識別子(hostname:pid:SecureRandom.hex(6))。
      SIDEKIQ_IDENTITY = /\A[^:\s]{1,253}:\d{1,10}:\h{12}\z/
      # [系統, 型, 識別子の後ろの語]。process(hash)・実行中の job(<識別子>:work の hash)・signal(<識別子>-signals の list)。
      SIDEKIQ_SHAPES = [%w[sidekiq-process hash] + [''], %w[sidekiq-process-work hash :work], %w[sidekiq-process-signals list -signals]].freeze
      SIDEKIQ_METRICS = /\A[a-z]\|\d{6,8}\|/
      POSTIZ_THROTTLER = /\A\{.+\}:(hits|blocked)\z/m
      RACK_ATTACK = 'rack::attack:'
      QUEUE = /\Aqueue:(.*)\z/m
      # Chatwoot v4.18.0 の config/sidekiq.yml の queue(Toybaco の overlay の queue_as もこの中だけ)。
      KNOWN_QUEUES = %w[critical high medium default mailers action_mailbox_routing low scheduled_jobs deferred purgable housekeeping
                        async_database_migration bulk_reindex_low active_storage_analysis active_storage_purge
                        action_mailbox_incineration].freeze
      KNOWN_FAMILIES = (%w[
        queues schedule retry dead processes stat cron_jobs cron_job
        ROUND_ROBIN_AGENTS IMAP_DELETED_MESSAGE CONVERSATION UNREAD_CONVERSATIONS USER_SSO_AUTH_TOKEN ONLINE_STATUS ONLINE_PRESENCE
        AUTHORIZATION_ERROR_COUNT REAUTHORIZATION_REQUIRED CHATWOOT_INSTALLATION_ONBOARDING LATEST_CHATWOOT_VERSION MESSAGE_SOURCE_KEY
        OPEN_AI_CONVERSATION_KEY WHATSAPP_CALL_TERMINATE_TOMBSTONE FB_MESSAGE_CREATE_LOCK IG_MESSAGE_CREATE_LOCK TIKTOK_MESSAGE_CREATE_LOCK
        TIKTOK_REFRESH_TOKEN_LOCK SLACK_MESSAGE_LOCK EMAIL_CHANNEL_LOCK WHATSAPP_MESSAGE_CREATE_LOCK CRM_PROCESS_MUTEX
        CAPTAIN_DOCUMENT_SYNC_LOCK CAPTAIN_CONVERSATION_FAQ_LOCK ASSIGNMENT AUTO_ASSIGNMENT_IN_FLIGHT ONBOARDING_ENRICHMENT
        HELP_CENTER_GENERATION OUTBOUND_EMAIL_COUNT CHATWOOT_CONFIG_RESET_WARNING V1.GLOBAL_CONFIG
        TOYBACO_GMAIL_FETCH TOYBACO_MICROSOFT_FETCH TOYBACO_CONNECTION_STATE TOYBACO_HANDOFF_MAIL_STATE TOYBACO_OIDC_CODE TOYBACO_OIDC_TOKEN
        TOYBACO_AGENT_LOGIN_USED TOYBACO_SUPPORT toybaco.admin_mfa toybaco.mfa-challenge toybaco.mfa-enrollment-attempts toybaco.upload-rate
        provider refresh onboarding redirect organization login external webhookUrl wallet integration integration-gmb-v2
        sidekiq-process sidekiq-process-work sidekiq-process-signals sidekiq-metrics rack-attack throttler-hits throttler-blocked
        queue.other
      ] + KNOWN_QUEUES.map { |queue| "queue.#{queue}" }).freeze

      module_function

      # [名前空間, 系統の生の値]。生の値は集計のキーとしてだけ使い、printable? を通ったものだけを出す。
      # type は TYPE の応答(Sidekiq の process を形と型で見分ける。読めなかった key は nil)。
      def classify(key, type)
        namespace, rest = split_namespace(key.to_s)
        [namespace, family_of(rest, type)]
      end

      def split_namespace(key)
        head, rest = key.split(':', 2)
        NAMESPACES.include?(head) && rest ? [head, rest] : [NONE, key]
      end

      def family_of(rest, type)
        sidekiq = sidekiq_family(rest, type)
        return sidekiq if sidekiq
        return 'sidekiq-metrics' if rest.match?(SIDEKIQ_METRICS)
        return 'rack-attack' if rest.start_with?(RACK_ATTACK)

        throttler = rest.match(POSTIZ_THROTTLER)
        return "throttler-#{throttler[1]}" if throttler

        segment_family(rest)
      end

      # Sidekiq の process の系統(SIDEKIQ_SHAPES)。形と型の両方が合う時だけ。
      def sidekiq_family(rest, type)
        SIDEKIQ_SHAPES.find do |_, shape_type, suffix|
          type == shape_type && rest.end_with?(suffix) && rest.delete_suffix(suffix).match?(SIDEKIQ_IDENTITY)
        end&.first
      end

      def segment_family(rest)
        queue = rest.match(QUEUE)
        return KNOWN_QUEUES.include?(queue[1]) ? "queue.#{queue[1]}" : 'queue.other' if queue

        first, second = rest.split(/:+/, 3)
        return "#{first}.#{second}" if first.to_s.match?(TWO_LEVEL) && second

        first.to_s
      end

      # 出してよい系統か。コードで定義した既知の語彙だけ(件数や文字の種類では決めない)。
      def printable?(family)
        KNOWN_FAMILIES.include?(family)
      end

      # { [名前空間, 系統の生の値] => { 列 => 件数 } } を出力の名前ごとに合算する。出せない系統は名前空間ごとの opaque にまとめる。
      # 返り値は名前の順の [[名前, { 列 => 件数 }], ...] で、列は columns の順。
      def collapse(families, columns)
        # ActiveSupport の index_with を使わずに 0 の行を作る(rake は Rails の初期化前にこのファイルを読むため)。
        rows = Hash.new { |hash, name| hash[name] = columns.zip(Array.new(columns.length, 0)).to_h }
        families.each do |(namespace, family), counts|
          row = rows[label(namespace, printable?(family) ? family : OPAQUE)]
          counts.each { |column, value| row[column] += value }
        end
        rows.sort_by(&:first)
      end

      # 名前空間は NAMESPACES と none の固定の語だけを出す(key 由来の文字列を名前空間として出さない)。
      def label(namespace, family)
        "#{(NAMESPACES + [NONE]).include?(namespace) ? namespace : 'other'}.#{token(family)}"
      end

      # ops-rake の出力の値。形が合わなければ other。
      def token(value)
        return NONE if value.nil? || value == ''
        return 'other' unless value.is_a?(String) && value.match?(TOKEN_FORMAT)

        value.tr('_', '-')
      end
    end
  end
end
