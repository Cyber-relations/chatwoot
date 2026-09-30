# frozen_string_literal: true

# 運営フラグ(S0-2 日次ダイジェスト、S1-2 店舗一覧、S0-1 利用者からの報告、使い方サポートの入口と AI 回答)の定義と読み手の正本。
# TOYBACO_SUPPORT_ENABLED は使い方サポートの入口(無効の間、/toybaco/support の API はすべて 404 を返す)。
# TOYBACO_SUPPORT_AI_ENABLED は使い方サポートの AI 回答(入口と両方が有効の時だけ、AI が登録済みの手順を選ぶ)。
# 値は installation_configs に JSON の boolean で置き、書くのは toybaco:ops_flag(lib/tasks/toybaco_ops.rake)だけ
# (staging の使い方サポートの 2 キーは scripts/support_staging_flags.rb も書くため、staging では ops_flag と併用しない)。
# 読み手は GlobalConfig の cache(Redis)を経由せず DB を直接読む(読むたびに SQL 1 本)。upstream の GlobalConfig.load_from_cache は
# cache miss の時に DB から読んだ値を無条件に SET する(CAS なし、TTL 1 日)ため、書き込みの前に DB を読んだ reader が
# 書き込みの後で古い値を cache に戻すと、DB と異なる判定が最大 1 日続く。
# rake は Rails の初期化前にこのファイルを読むため、モジュールは入れ子で定義し、InstallationConfig は呼び出し時に参照する。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    module OpsFlag
      # ops-rake workflow の契約テスト(tests/ops-rake-workflow.test.mjs)がこの定義を 1 行の %w として照合するため、行の長さの検査だけを外す。
      # rubocop:disable Layout/LineLength
      OPS_FLAGS = %w[TOYBACO_OPS_DIGEST_ENABLED TOYBACO_OPS_CONSOLE_ENABLED TOYBACO_SUPPORT_REPORTS_ENABLED TOYBACO_SUPPORT_ENABLED TOYBACO_SUPPORT_AI_ENABLED].freeze
      # rubocop:enable Layout/LineLength

      module_function

      # JSON の boolean true の時だけ有効。行が無い・false・文字列の "true" などはすべて無効。
      def enabled?(key)
        current(key).equal?(true)
      end

      # DB の生値(行が無ければ nil)。運営フラグ以外のキーは読まない。
      def current(key)
        raise ArgumentError, "運営フラグではないキーです: #{key.inspect}" unless OPS_FLAGS.include?(key)

        InstallationConfig.find_by(name: key)&.value
      end

      # run ログに出す値。boolean はそのまま、行が無ければ unset、文字列の "true" / "false" は画面で保存された文字列と
      # 見分けられるよう引用符付きで出す。それ以外は任意の文字列が入り得るため、中身も長さも出さず non_boolean にする。
      def state(value)
        case value
        when true, false then value.to_s
        when nil then 'unset'
        when 'true', 'false' then value.inspect
        else 'non_boolean'
        end
      end
    end
  end
end
