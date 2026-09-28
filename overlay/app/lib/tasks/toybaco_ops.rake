# frozen_string_literal: true

# 運営操作の監査(S1-1)。toybaco:* の rake 実行を Toybaco::Ops::Audit.around で包み、開始(started)と終了(ok / failed)を
# 呼び出し元とは別の DB セッションで toybaco_operator_actions に残す。db:* などほかの名前空間のタスクは包まない。
# rake -n(dry-run)は本体を実行しないので包まない。
# 実行者は ENV['TOYBACO_OPS_ACTOR'](空なら unknown)、出どころは ENV['TOYBACO_OPS_SOURCE'](空なら rake:unspecified)。
# ops-rake workflow は名簿照合を通った GitHub login と ops-rake-<run id>-<attempt> を run-task の環境変数で渡すが、
# 直接 run-task した値もここで形を確かめ、合わなければ偽装せずに失敗させる(started も書かない)。
# 引数は digest だけを残す(宣言していない余剰引数 extras も含める)。監査を書けなければタスクも失敗させ、
# テーブルが無い DB でも握りつぶさない(fail-closed)。
# rake は Rails の初期化前にこのファイルを読むため、モジュールは入れ子で定義し、Toybaco::Ops::Audit は実行時に参照する。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    module RakeAudit
      # ops-rake workflow の検査と同じ形(GitHub の login と、出どころの識別子)。
      ACTOR_FORMAT = /\A[A-Za-z0-9-]{1,39}\z/
      SOURCE_FORMAT = /\A[A-Za-z0-9:_.-]{1,128}\z/

      def execute(args = nil)
        return super if !name.start_with?('toybaco:') || application.options.dryrun

        Toybaco::Ops::Audit.around(actor_kind: 'rake', actor_id: toybaco_audit_env('TOYBACO_OPS_ACTOR', ACTOR_FORMAT, 'unknown'),
                                   action: "rake.#{name}", params: toybaco_audit_params(args),
                                   source: toybaco_audit_env('TOYBACO_OPS_SOURCE', SOURCE_FORMAT, 'rake:unspecified')) { super(args) }
      end

      private

      # 未設定・空(空白だけを含む)なら従来どおり既定値。値があれば形を確かめ、合わなければ値を出さずに例外にする。
      def toybaco_audit_env(name, format, fallback)
        value = ENV.fetch(name, nil)
        return fallback if value.blank?
        raise ArgumentError, "#{name} の形式が不正なため、監査行に書けず実行しません" unless value.match?(format)

        value
      end

      # 宣言した引数に、カンマ過多の余剰引数(extras)があれば '_extras' として足す(extras が無ければ従来の digest のまま)。
      def toybaco_audit_params(args)
        params = args.to_h
        extras = args.respond_to?(:extras) ? args.extras : []
        extras.empty? ? params : params.merge('_extras' => extras)
      end
    end
  end
end

Rake::Task.prepend(Toybaco::Ops::RakeAudit) unless Rake::Task < Toybaco::Ops::RakeAudit

namespace :toybaco do
  desc '運営操作の監査ログの直近を id の新しい順に表示する(rake toybaco:audit_tail[件数]。件数は 1〜999、省略時 50)'
  task :audit_tail, [:limit] => :environment do |_t, args|
    raw = args[:limit].to_s
    abort '件数は 1〜999 の整数で指定してください。' unless raw.empty? || raw.match?(/\A[1-9]\d{0,2}\z/)

    limit = raw.empty? ? 50 : Integer(raw, 10)
    Toybaco::OperatorAction.order(id: :desc).limit(limit).each { |row| puts Toybaco::Ops::Audit.tail_line(row) }
  end
end
