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
# 運営フラグの定義と読み手(Toybaco::Ops::OpsFlag)も同じ理由で入れ子に定義してあり、ここで先に読む。
require_relative '../toybaco/ops/ops_flag'
# メール接続の開放(Toybaco::Ops::ConnectionReleaseOps)も同じ。
require_relative '../toybaco/ops/connection_release_ops'

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

  # 監査行(started / ok|failed)は上の RakeAudit が書き、params_digest に name と value が入る。
  # 出力はフラグ名・値・前の値の 1 行と、OPS_FLAGS の各キーの現在値(1 キー 1 行)。値は OpsFlag.state で表し、文字列の中身は出さない。
  desc '運営フラグを JSON の boolean で切り替える(rake "toybaco:ops_flag[フラグ名,true|false]"。フラグ名は OPS_FLAGS のキー)'
  task :ops_flag, %i[name value] => :environment do |_t, args|
    flag = Toybaco::Ops::OpsFlag
    name = args[:name]
    raw = args[:value]
    abort "フラグ名は #{flag::OPS_FLAGS.join(' / ')} のいずれかを指定してください。" unless flag::OPS_FLAGS.include?(name)
    # 検査と代入を同じ判定にする(通すのは文字列の 'true' / 'false' だけで、Ruby から boolean を渡しても通さない)。
    abort '値は true か false を指定してください。' unless raw.is_a?(String) && %w[true false].include?(raw)
    abort '引数はフラグ名と値の 2 つだけを指定してください(1 回に切り替えるフラグは 1 つ)。' unless args.extras.empty?

    value = raw == 'true'
    config = InstallationConfig.find_or_initialize_by(name: name)
    previous = config.value
    config.value = value
    # SuperAdmin の installation_configs 画面は locked: false の行を一覧・編集でき、画面で編集すると文字列に化けるため隠す。
    config.locked = true
    # 読み直しは読み手と同じ DB 直読で、同じ接続・同じ transaction の中で行う。合わなければ abort(SystemExit)で rollback して
    # 保存しない(監査の failed は未保存)。GlobalConfig の cache の消去はモデルの after_commit が行う(読み手は cache を読まない)。
    InstallationConfig.transaction do
      config.save!
      unless flag.enabled?(name) == value && flag.current(name).equal?(value)
        abort "#{name} の読み直しが boolean の #{value} にならないため保存しません。installation_configs を確認してください。"
      end
    end

    puts "TOYBACO_OPS_FLAG name=#{name} value=#{value} previous=#{flag.state(previous)}"
    # 監査行は引数の digest しか持たないため、run ログで全運営フラグの状態を読めるようにする。
    flag::OPS_FLAGS.each { |key| puts "TOYBACO_OPS_FLAG_STATE name=#{key} value=#{flag.state(flag.current(key))}" }
  end
end

# メール接続(Gmail / Microsoft)の開放(審査・評価・実測の記録、緊急停止、担当者依頼メールの登録)。実装と読み直しは
# Toybaco::Ops::ConnectionReleaseOps にあり、ここは出力だけを行う。監査行(started / ok|failed)は上の RakeAudit が書く。
# provider は開放判定のキー gmail_rest / microsoft_graph(担当者依頼メールだけは gmail / microsoft)。時刻は UTC の YYYY-MM-DDTHH:MM:SSZ。
namespace :toybaco do
  desc 'メール接続の開放判定と記録を表示する(rake "toybaco:connection_release_show[gmail_rest|microsoft_graph]")'
  task :connection_release_show, %i[provider] => :environment do |_t, args|
    puts Toybaco::Ops::ConnectionReleaseOps.show(args)
  end

  desc '提供元の承認・セキュリティ評価を記録する(rake "toybaco:connection_release_approve[provider,approval|qualification,証跡ID,確認時刻,期限|none]")'
  task :connection_release_approve, %i[provider kind evidence_ref observed_at expires_at] => :environment do |_t, args|
    puts Toybaco::Ops::ConnectionReleaseOps.approve(args)
  end

  desc '実測した接続確認を記録する(rake "toybaco:connection_release_smoke[provider,証跡ID,確認時刻,合格項目を.で区切る]")'
  task :connection_release_smoke, %i[provider evidence_ref observed_at checks] => :environment do |_t, args|
    puts Toybaco::Ops::ConnectionReleaseOps.smoke(args)
  end

  desc 'メール接続を緊急停止・解除する(rake "toybaco:connection_release_disable[provider,on|off]")'
  task :connection_release_disable, %i[provider state] => :environment do |_t, args|
    puts Toybaco::Ops::ConnectionReleaseOps.disable(args)
  end

  desc 'staging の開放記録を消す(fixture の後片付け。rake "toybaco:connection_release_clear[provider]")'
  task :connection_release_clear, %i[provider] => :environment do |_t, args|
    puts Toybaco::Ops::ConnectionReleaseOps.clear(args)
  end

  desc '担当者依頼メールの登録を書く・依頼の有効化を戻す(rake "toybaco:connection_handoff_mail[gmail|microsoft,enable|keep|disable]")'
  task :connection_handoff_mail, %i[provider mode] => :environment do |_t, args|
    puts Toybaco::Ops::ConnectionReleaseOps.handoff_mail(args)
  end
end

# 規約同意の記録の確認(法務チェックリスト第 2 節)。記録は Account の internal_attributes の toybaco_legal_consents
# (追記のみの配列)にあり、正本の読み手 Toybaco::LegalTerms.records で読む。読み取りだけで書き込まない。
# 監査行(started / ok|failed)は上の RakeAudit が書く。出力は 1 件 1 行の TOYBACO_LEGAL_CONSENT と、最後に件数と
# 経路ごとの件数を示す TOYBACO_LEGAL_CONSENTS の 1 行。各値は LegalTerms の検査(書き込み時と同じ)を通るものだけを出し、
# 通らなければ中身を出さずに invalid と出す。利用者は id だけ、Session は先頭 8 字だけを出し、メールアドレス・氏名・
# Session の全体・Stripe の顧客 ID は出さない。rake は Rails の初期化前にこのファイルを読むため、LegalTerms は実行時に参照する。
# 経路の表記はマスク回避のためハイフン(記録の値は ROUTES のまま)。ops-rake の Step Summary のマスクは「小文字 2〜8 字 + _ +
# 英数字 8 字以上」を ID として伏せ、opening_checkout などを <id> にするため、行と集計では _ を - に置き換えて出す。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    module LegalConsentsReport
      ACCOUNT_ID_FORMAT = /\A[1-9]\d{0,9}\z/
      FIELDS = %w[route terms_version accepted_at user_id session stripe_consent].freeze
      SESSION_PREFIX_LENGTH = 8
      INVALID = 'invalid'
      NONE = '-'

      module_function

      def lines(account)
        rows = Toybaco::LegalTerms.records(account).map { |record| row(record) }
        rows.map { |row| entry_line(account.id, row) } + [summary_line(account.id, rows)]
      end

      # 出力の項目は FIELDS の順。Hash でない記録は全項目を invalid にする。
      def row(record)
        return FIELDS.index_with(INVALID) unless record.is_a?(Hash)

        legal = Toybaco::LegalTerms
        { 'route' => legal::ROUTES.include?(record['route']) ? route_label(record['route']) : INVALID,
          'terms_version' => checked { legal.version!(record['terms_version']) },
          'accepted_at' => checked { legal.timestamp!(record['accepted_at']) },
          'user_id' => checked { legal.user!(record['user_id']) } || NONE,
          'session' => session(record['session_id']),
          'stripe_consent' => checked { legal.stripe_consent!(record['stripe_consent']) } || NONE }
      end

      # 経路の表記(マスク回避のため ROUTES の値の _ を - に置き換える。記録の値は ROUTES のまま)。
      def route_label(route)
        route.tr('_', '-')
      end

      # LegalTerms の検査を通った値(記録が無い項目は nil)を返し、通らなければ中身を出さずに invalid にする。
      def checked
        yield
      rescue ArgumentError
        INVALID
      end

      # Session は先頭 8 字だけを出す。8 字以下の Session は先頭 8 字が全体になるため cs_ だけを出す。
      def session(value)
        return NONE if value.nil?
        return INVALID unless value.is_a?(String) && value.match?(Toybaco::LegalTerms::SESSION_FORMAT)

        value.length > SESSION_PREFIX_LENGTH ? "#{value[0, SESSION_PREFIX_LENGTH]}…" : 'cs_…'
      end

      def entry_line(account_id, row)
        fields = row.map { |key, value| "#{key}=#{value}" }.join(' ')
        "TOYBACO_LEGAL_CONSENT account=#{account_id} #{fields}"
      end

      # 経路ごとの件数は LegalTerms::ROUTES の順(表記はハイフン、形に合わない経路の invalid は最後)で、記録のある経路だけを出す。
      # 記録が無ければ -。
      def summary_line(account_id, rows)
        counts = rows.pluck('route').tally
        order = Toybaco::LegalTerms::ROUTES.map { |route| route_label(route) } + [INVALID]
        routes = order.filter_map { |route| "#{route}:#{counts[route]}" if counts.key?(route) }
        "TOYBACO_LEGAL_CONSENTS account=#{account_id} count=#{rows.size} routes=#{routes.empty? ? NONE : routes.join(',')}"
      end
    end
  end
end

namespace :toybaco do
  desc '規約同意の記録を読み取りだけで表示する(rake "toybaco:legal_consents[account_id]"。account_id は 1 以上の整数)'
  task :legal_consents, %i[account_id] => :environment do |_t, args|
    report = Toybaco::Ops::LegalConsentsReport
    raw = args[:account_id]
    # 検査と変換を同じ判定にする(通すのは 1 以上の整数の文字列だけで、Ruby から Integer を渡しても通さない)。入力の値は出さない。
    abort 'account_id は 1 以上の整数で指定してください。' unless raw.is_a?(String) && raw.match?(report::ACCOUNT_ID_FORMAT)
    abort '引数は account_id の 1 つだけを指定してください。' unless args.extras.empty?

    account_id = Integer(raw, 10)
    account = Account.find_by(id: account_id)
    abort "account=#{account_id} が見つかりません。" unless account

    report.lines(account).each { |line| puts line }
  end
end
