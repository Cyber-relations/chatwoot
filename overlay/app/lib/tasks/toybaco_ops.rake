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

# staging の E2E(規約同意の記録の経路の確認)用。引数は E2E の店舗名の prefix(e2e-consent- で始まる形)だけ(確認 token の設定と
# 担当者の招待だけは prefix と token)で、E2E の利用者のメールアドレスも e2e-consent- を含む形に限り、実顧客の店舗・利用者には当たらない
# ようにする。読み取り(legal_consents_by_name)は両環境で使え、書き込み(e2e_confirm_user / e2e_confirmation_token / e2e_invite_agent /
# e2e_purge_accounts)と、確認の段階の読み取り(e2e_registration_phase)は staging 専用。環境の判定は ConnectionReleaseOps と同じ Input.staging?
# (TOYBACO_DEPLOYMENT_ENVIRONMENT)で、production と環境が不明なときは引数を読む前に abort する。ops-rake workflow も e2e_ で始まるタスクを
# staging 以外では拒否する(二重の fail-closed)。出力は ID・経路・段階だけで、メールアドレス・氏名は出さない。監査行(started / ok|failed)は
# 上の RakeAudit が書く。rake は Rails の初期化前にこのファイルを読むため、モデルとジョブは実行時に参照する。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    module E2eConsent
      NAME_PREFIX = 'e2e-consent-'
      PREFIX_FORMAT = /\Ae2e-consent-[a-z0-9-]{1,40}\z/
      PREFIX_ERROR = 'prefix は e2e-consent- に続けて英小文字・数字・- を 1〜40 字で指定してください。'
      # 書き込みの 2 本(確認・削除)が扱う店舗名の厳格な形。staging E2E の run ごとの店舗名 e2e-consent-r<run id>-<attempt> だけ。
      # prefix に一致してもこの形でない店舗(例: 実店舗の e2e-consent-registration)が 1 件でもあれば、どちらも何もせずに abort する。
      RUN_NAME_FORMAT = /\Ae2e-consent-r\d{1,20}-\d{1,3}\z/
      # E2E の利用者のメールアドレスの形。受信箱の plus addressing(<local>+e2e-consent-<tag>@<domain>)か、local 部が e2e-consent-<tag>
      # そのものの形だけ。確認と削除で E2E の利用者だけを扱うために使う。登録時のメールアドレスは小文字にそろえて保存されるため、大文字は通さない。
      EMAIL_FORMAT = /\A(?:[a-z0-9][a-z0-9._-]{0,63}\+)?e2e-consent-[a-z0-9-]{1,40}@(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/
      PURGE_LIMIT = 5
      PHASE_FORMAT = /\A[a-z_]{1,32}\z/
      # E2E の rake の出力行の契約の版(toybaco:e2e_preflight が出す)。E2E の rake の出力行の形を変える PR で上げ、staging の同意 E2E の
      # one-shot が image の rake と自分の照合の版の食い違いを、後段の rake_failed / output_missing を待たずに先に止められるようにする。
      RAKE_CONTRACT = 1

      module_function

      def staging!(task)
        return if Toybaco::Ops::ConnectionReleaseOps::Input.staging?

        abort "#{task} は staging 専用です。production と環境が不明なときは実行しません。"
      end

      # 検査と代入を同じ判定にする(通すのは形に合う文字列だけで、Symbol などは通さない)。入力の値は出さない。
      def argument!(args, key, format, message)
        value = args[key]
        abort message unless value.is_a?(String) && value.match?(format)
        abort "引数は #{key} の 1 つだけを指定してください。" unless args.extras.empty?

        value
      end

      def prefix!(args)
        argument!(args, :prefix, PREFIX_FORMAT, PREFIX_ERROR)
      end

      # 名前が prefix で始まる店舗(id の順)。LIKE で絞り、Ruby でも前方一致を確かめる。
      def accounts(prefix)
        Account.where('name LIKE ?', "#{Account.sanitize_sql_like(prefix)}%").order(:id).select { |account| account.name.start_with?(prefix) }
      end

      # toybaco:legal_consents_by_name[prefix]。店舗ごとに legal_consents と同じ行を出し、最後に一致した店舗の数を 1 行で出す。
      def consents_by_name(args)
        prefix = prefix!(args)
        found = accounts(prefix)
        found.flat_map { |account| LegalConsentsReport.lines(account) } + ["TOYBACO_LEGAL_CONSENTS_BY_NAME prefix=#{prefix} accounts=#{found.size}"]
      end

      # toybaco:e2e_confirm_user[prefix]。名前が prefix で始まる店舗のうち無料登録がメール確認待ち(phase=email_pending)のもの(1 回 5 件まで)の
      # 契約者(登録時の owner)を、確認メールのリンク(DeviseOverrides::ConfirmationsController)と同じ User#confirm で確認し、選んだ店舗ごとに
      # FreeActivationJob の中と同じ FreeRegistration#activate! で有効にする(job は利用者のメール確認待ちの店舗を全て有効にするため使わない)。
      # 全体を 1 つの transaction で行い、選んだ店舗と契約者を行ロックして全て確かめ直してから確認・有効化し、段階を読み直す。どこかで止まれば
      # abort(SystemExit)か例外で transaction ごと取り消し、確認も有効化も残さない(確認と有効化は job を積まない。spec で確かめる)。
      # 対象が 0 件でも正常に終わる。メールアドレスは引数にも出力にも出さない。
      def confirm(args)
        staging!('e2e_confirm_user')
        prefix = prefix!(args)
        lines = ActiveRecord::Base.transaction { confirm_selected!(prefix) }
        lines + ["TOYBACO_E2E_CONFIRM prefix=#{prefix} accounts=#{lines.size}"]
      end

      # transaction の中で呼ぶ。店舗を選び、行ロックして名前と段階を確かめ直し、契約者を確かめてから確認・有効化する。
      def confirm_selected!(prefix)
        pending = run_names!(prefix, accounts(prefix), '確認').select { |account| phase(account) == 'email_pending' }
        selected = within_limit!(prefix, pending, 'メール確認待ちの店舗', '確認')
        WriteGuard.relock!(prefix, selected, '確認') { |account| phase(account) == 'email_pending' }
        confirm_and_activate!(selected.index_with { |account| owner!(account, selected.map(&:id)) })
      end

      # 契約者を全て確かめ終えた後に transaction の中で呼ぶ。契約者を確認してから、選んだ店舗ごとに有効にし、段階を読み直した行を返す。
      def confirm_and_activate!(owners)
        owners.values.uniq.each { |user| confirm_user!(user) }
        owners.each { |account, user| Toybaco::Growth::FreeRegistration.new.activate!(user, account) }
        activated_lines!(owners)
      end

      # 店舗ごとに段階を読み直した行。active でない店舗があれば abort する。
      def activated_lines!(owners)
        lines = owners.map { |account, user| "TOYBACO_E2E_CONFIRM user=#{user.id} account=#{account.id} phase=#{phase(account.reload)}" }
        inactive = lines.reject { |line| line.end_with?(' phase=active') }
        abort "無料登録が有効になっていない店舗があります(#{inactive.join(' / ')})。" if inactive.any?

        lines
      end

      # 無料登録の契約者(登録時の owner)。所属の書き手と同じ users の行ロックを取ってから確かめる。E2E の利用者でないか、選んだ店舗の外にも
      # メール確認待ちの店舗を持てば(確認すると確認メールのリンクと同じくその店舗も有効になる)、利用者の id だけを出して abort する。
      def owner!(account, selected_ids)
        user = User.find_by(id: Toybaco::Entitlements.attributes(account)[Toybaco::Growth::FreeRegistration::KEY]['owner_id'])
        abort "account=#{account.id} の無料登録の契約者が見つかりません。" unless user

        user.reload(lock: true)
        abort "account=#{account.id} の契約者 user=#{user.id} は E2E の利用者ではないため確認しません。" unless e2e_user?(user)
        return user unless other_pending?(user, selected_ids)

        abort "account=#{account.id} の契約者 user=#{user.id} は選んだ店舗の外にもメール確認待ちの店舗を持つため確認しません。"
      end

      # E2E の利用者: SuperAdmin(type あり)でなく、メールアドレスが E2E 用の形で、名前が e2e-consent- で始まる店舗だけに所属する。
      def e2e_user?(user)
        stores = user.accounts.to_a
        user.type.blank? && user.email.to_s.match?(EMAIL_FORMAT) && stores.any? && stores.all? { |store| store.name.start_with?(NAME_PREFIX) }
      end

      # 確認の commit 後の処理(Growth::FreeConfirmation)と同じ条件で、選んだ店舗の外のメール確認待ちの店舗があるか。
      def other_pending?(user, selected_ids)
        user.accounts.where("internal_attributes -> 'toybaco_growth_registration' ->> 'phase' = 'email_pending'").where.not(id: selected_ids).exists?
      end

      # 確認済みならそのまま進む(再実行しても同じ結果になる)。確認できなければ理由の種類(属性と error のキー)だけを出す。
      def confirm_user!(user)
        return if user.confirmed? || user.confirm

        reasons = user.errors.details.flat_map { |attribute, errors| errors.map { |error| "#{attribute}.#{error[:error]}" } }
        abort "user=#{user.id} のメール確認を記録できません(#{reasons.join(',')})。"
      end

      # 確認メールのリンクの確認の HTTP 経路(POST /auth/confirmation)を、受信箱を使わずに実ブラウザーで通すための 2 本
      # (toybaco:e2e_confirmation_token / toybaco:e2e_registration_phase)。環境の判定・prefix の形・店舗の選び方・行ロックの読み直し・
      # E2E の利用者の検査・段階の正規化は E2eConsent のものをそのまま使う。
      module Confirmation
        # 受け取る token の形。runner が作る 256 bit の乱数を英小文字の 16 進数 64 桁で渡す(確認画面の token の形 [A-Za-z0-9_-] に
        # 収まり、rake の引数の区切り(, [ ] 空白)を含まない)。
        TOKEN_FORMAT = /\A[0-9a-f]{64}\z/
        ACTION = '確認 token を設定'

        module_function

        # toybaco:e2e_confirmation_token[prefix,token]。名前が prefix で始まる店舗(E2E の run ごとの店舗名の形で、ちょうど 1 件)が
        # メール確認待ちで、契約者が未確認の E2E の利用者なら、契約者の確認 token を runner が作った値にする。Devise の確認 token は DB に
        # 生値で保存され、確認の HTTP 経路は生値の一致で利用者を引く。書き込みは update_columns で、callback・検証・メール送信を通さない
        # (確認はしない。登録時のメールの token は無効になる)。もう一度呼べば新しい token で上書きする。全体を 1 つの transaction で行い、
        # confirm と同じく店舗と契約者を行ロックして確かめ直してから書く。進めないときは理由の 1 行(TOYBACO_E2E_CONFIRMATION_TOKEN …
        # result=refused)で abort する。token は出力・abort の文・例外のどこにも出さない(監査行は RakeAudit が prefix と token の
        # digest だけを残す)。
        def confirmation_token(args)
          E2eConsent.staging!('e2e_confirmation_token')
          prefix, token = confirmation_arguments!(args)
          ActiveRecord::Base.transaction { assign!(prefix, token) }
        end

        # 検査と代入を同じ判定にする(通すのは形に合う文字列 2 つだけで、Symbol・nil・余分な引数は通さない)。入力の値は出さない。
        def confirmation_arguments!(args)
          prefix = args[:prefix]
          token = args[:token]
          abort PREFIX_ERROR unless prefix.is_a?(String) && prefix.match?(PREFIX_FORMAT)
          abort 'token は英小文字の 16 進数 64 桁で指定してください。' unless token.is_a?(String) && token.match?(TOKEN_FORMAT)
          abort '引数は prefix と token の 2 つだけを指定してください。' unless args.extras.empty?

          [prefix, token]
        end

        # transaction の中で呼ぶ。店舗を選び、行ロックして名前と段階を確かめ直し、契約者を確かめてから token を書く。同じ token を持つ
        # 別の利用者がいれば書かない(confirmation_token に一意の index は無く、確認の HTTP 経路は token の一致で最初の 1 人を引く)。
        def assign!(prefix, token)
          account = store!(prefix, E2eConsent.run_names!(prefix, E2eConsent.accounts(prefix), ACTION))
          WriteGuard.relock!(prefix, [account], ACTION) { |store| E2eConsent.phase(store) == 'email_pending' }
          user = owner!(prefix, account)
          refuse!(prefix, account, 'token_in_use') if User.where(confirmation_token: token).where.not(id: user.id).exists?

          user.update_columns(confirmation_token: token, confirmation_sent_at: Time.now.utc) # rubocop:disable Rails/SkipsModelValidations
          "TOYBACO_E2E_CONFIRMATION_TOKEN prefix=#{prefix} user=#{user.id} account=#{account.id} phase=email_pending result=set"
        end

        # token を設定する店舗。prefix に一致する店舗がちょうど 1 件で、メール確認待ち(phase=email_pending)であること。
        def store!(prefix, stores)
          refuse!(prefix, nil, 'no_account') if stores.empty?
          refuse!(prefix, nil, 'multiple_accounts') if stores.size > 1
          refuse!(prefix, stores.first, 'not_email_pending') unless E2eConsent.phase(stores.first) == 'email_pending'

          stores.first
        end

        # 無料登録の契約者を行ロックして読み直し、token を書いてよいか確かめる。E2eConsent.owner! と同じ検査(E2E の利用者で、選んだ
        # 店舗の外にメール確認待ちの店舗を持たない)に、所属が選んだ店舗 1 件だけであること、未確認であること、メールアドレスの変更の
        # 再確認待ち(unconfirmed_email)でないことを足し、理由を固定の語で出す。e2e_user? は所属先の名前が e2e-consent- で始まれば通すため、
        # 名前だけが E2E 風の実店舗(例: e2e-consent-registration)にも所属する契約者に token を書くと、ブラウザーでの確認でその店舗の
        # 資格情報まで出る。無料登録の直後の契約者は所属が登録した店舗 1 件だけなので、それ以外は書かない。
        def owner!(prefix, account)
          user = User.find_by(id: Toybaco::Entitlements.attributes(account)[Toybaco::Growth::FreeRegistration::KEY]['owner_id'])
          refuse!(prefix, account, 'owner_missing') unless user

          user.reload(lock: true)
          refuse!(prefix, account, 'not_e2e_user') unless E2eConsent.e2e_user?(user)
          refuse!(prefix, account, 'other_pending') if E2eConsent.other_pending?(user, [account.id])
          refuse!(prefix, account, 'other_memberships') unless AccountUser.where(user_id: user.id).pluck(:account_id) == [account.id]
          refuse!(prefix, account, 'already_confirmed') if user.confirmed?
          refuse!(prefix, account, 'unconfirmed_email') if user.unconfirmed_email.present?

          user
        end

        # 進めないときの 1 行で abort する(transaction の中なら rollback する)。reason は固定の語([a-z_])で、入力の値・メールアドレスは
        # 出さない。
        def refuse!(prefix, account, reason)
          abort "TOYBACO_E2E_CONFIRMATION_TOKEN prefix=#{prefix} result=refused account=#{account&.id || LegalConsentsReport::NONE} reason=#{reason}"
        end

        # toybaco:e2e_registration_phase[prefix]。名前が prefix で始まる店舗(id の順)ごとに、無料登録の契約者・段階・契約者の確認の
        # 有無を読み取りだけで 1 行ずつ出し、最後に店舗の数を出す(ブラウザーで確認した後の段階の確認。phase=active confirmed=true を
        # 見る)。読み取りなので店舗名の厳格な形(RUN_NAME_FORMAT)は求めない。DB へ書かず、job も積まない。メールアドレス・氏名は出さない。
        def registration_phase(args)
          E2eConsent.staging!('e2e_registration_phase')
          prefix = E2eConsent.prefix!(args)
          found = E2eConsent.accounts(prefix)
          found.map { |account| registration_line(account) } + ["TOYBACO_E2E_REGISTRATION_SUMMARY prefix=#{prefix} accounts=#{found.size}"]
        end

        # 契約者は無料登録の記録の owner_id(Integer)の利用者。記録・利用者が無ければ user と confirmed は -。段階は E2eConsent.phase と
        # 同じ正規化。
        def registration_line(account)
          state = Toybaco::Entitlements.attributes(account)[Toybaco::Growth::FreeRegistration::KEY]
          owner_id = state.is_a?(Hash) ? state['owner_id'] : nil
          owner = owner_id.is_a?(Integer) ? User.find_by(id: owner_id) : nil
          none = LegalConsentsReport::NONE
          "TOYBACO_E2E_REGISTRATION user=#{owner&.id || none} account=#{account.id} phase=#{E2eConsent.phase(account)} " \
            "confirmed=#{owner ? owner.confirmed? : none}"
        end
      end

      # 招待 → パスワード設定の HTTP 経路(招待メールのリンク /app/auth/password/edit?reset_password_token=… の画面が送る
      # PUT /auth/password)を、招待メールを送らずに実ブラウザーで通すための 1 本(toybaco:e2e_invite_agent)。引数の検査は
      # Confirmation の確認 token の設定と同じで(token の形も同じ)、環境の判定・prefix の形・店舗の選び方・行ロックの読み直し・
      # E2E の利用者の検査・段階の正規化は E2eConsent のものをそのまま使う。
      module Invitation
        ACTION = '担当者を招待'
        INVITEE_NAME = 'E2E 招待 担当者'
        # 契約者のメールアドレスのうち、受信箱の plus addressing の形(<local>+e2e-consent-<tag>@<domain>)。招待先は同じ受信箱の別の
        # tag(<local>+<prefix>-invite@<domain>)にする。local 部が e2e-consent-<tag> そのものの形の契約者は、招待先の作り方が決まって
        # いないため招待しない(invite_email_format)。
        OWNER_EMAIL_FORMAT = /\A(?<local>[a-z0-9][a-z0-9._-]{0,63})\+e2e-consent-[a-z0-9-]{1,40}@(?<domain>[^@+]+)\z/

        module_function

        # toybaco:e2e_invite_agent[prefix,token]。名前が prefix で始まる店舗(E2E の run ごとの店舗名の形で、ちょうど 1 件)が有効
        # (無料登録の phase=active)で、契約者が確認済みの E2E の利用者なら、upstream の AgentBuilder が行うことのうちメール送信を除いた
        # 部分(仮パスワードの利用者を確認の通知を止めて作り、店舗の agent として所属させる。招待した人は契約者)を行い、招待先の
        # パスワード再設定 token を runner が作った値の digest にする(Devise は再設定 token を digest で保存し、PUT /auth/password は
        # 受け取った生値の digest で利用者を引く。DB に生値は残らない)。招待先は未確認のまま(PUT /auth/password が確認とパスワードの
        # 設定を同時に行う)。確認・招待・再設定のメールは送らない(送信の処理を呼ばない)。全体を 1 つの transaction で行い、店舗と
        # 契約者を行ロックして確かめ直してから書く。進めないときは理由の 1 行(TOYBACO_E2E_INVITE … result=refused)で abort する。
        # token・仮パスワード・メールアドレスは出力・abort の文・例外のどこにも出さない(監査行は RakeAudit が prefix と token の digest
        # だけを残す)。招待先は E2E 用のメールアドレスで所属がこの店舗だけなので、e2e_purge_accounts が契約者と一緒に消す。
        def invite_agent(args)
          E2eConsent.staging!('e2e_invite_agent')
          prefix, token = Confirmation.confirmation_arguments!(args)
          ActiveRecord::Base.transaction { invite!(prefix, token) }
        end

        # transaction の中で呼ぶ。店舗を選び、行ロックして名前と段階を確かめ直し、契約者と招待先のメールアドレスを確かめてから書く。
        # 同じメールアドレスの利用者が既にいれば(前の run の残り。消すのは purge の仕事)作らない。
        def invite!(prefix, token)
          account = store!(prefix, E2eConsent.run_names!(prefix, E2eConsent.accounts(prefix), ACTION))
          WriteGuard.relock!(prefix, [account], ACTION) { |store| E2eConsent.phase(store) == 'active' }
          owner = owner!(prefix, account)
          email = invitee_email!(prefix, account, owner)
          refuse!(prefix, account, 'invitee_exists') if User.from_email(email)

          invitee = create_invitee!(account, owner, email)
          digest = Devise.token_generator.digest(User, :reset_password_token, token)
          invitee.update_columns(reset_password_token: digest, reset_password_sent_at: Time.now.utc) # rubocop:disable Rails/SkipsModelValidations
          "TOYBACO_E2E_INVITE prefix=#{prefix} user=#{invitee.id} account=#{account.id} owner=#{owner.id} result=invited"
        end

        # 招待する店舗。prefix に一致する店舗がちょうど 1 件で、無料登録が有効(phase=active。契約者の確認の後)であること。
        def store!(prefix, stores)
          refuse!(prefix, nil, 'no_account') if stores.empty?
          refuse!(prefix, nil, 'multiple_accounts') if stores.size > 1
          refuse!(prefix, stores.first, 'not_active') unless E2eConsent.phase(stores.first) == 'active'

          stores.first
        end

        # 無料登録の契約者を行ロックして読み直し、招待してよいか確かめる。Confirmation.owner! と同じ検査(E2E の利用者で、選んだ店舗の
        # 外にメール確認待ちの店舗を持たず、所属が選んだ店舗 1 件だけで、メールアドレスの変更の再確認待ちでない)の、確認の有無だけを
        # 逆にしたもの(招待は確認済みの契約者だけ)。理由の語は Confirmation と揃える。
        def owner!(prefix, account)
          user = User.find_by(id: Toybaco::Entitlements.attributes(account)[Toybaco::Growth::FreeRegistration::KEY]['owner_id'])
          refuse!(prefix, account, 'owner_missing') unless user

          user.reload(lock: true)
          refuse!(prefix, account, 'not_e2e_user') unless E2eConsent.e2e_user?(user)
          refuse!(prefix, account, 'other_pending') if E2eConsent.other_pending?(user, [account.id])
          refuse!(prefix, account, 'other_memberships') unless AccountUser.where(user_id: user.id).pluck(:account_id) == [account.id]
          refuse!(prefix, account, 'not_confirmed') unless user.confirmed?
          refuse!(prefix, account, 'unconfirmed_email') if user.unconfirmed_email.present?

          user
        end

        # 招待先のメールアドレス。契約者の <local>+e2e-consent-<tag>@<domain> から <local>+<prefix>-invite@<domain> を作り
        # (prefix は e2e-consent- で始まる)、小文字にして E2E 用の形(EMAIL_FORMAT)に合うことを確かめる。合わなければ作らない。
        def invitee_email!(prefix, account, owner)
          parts = owner.email.to_s.match(OWNER_EMAIL_FORMAT)
          email = parts && "#{parts[:local]}+#{prefix}-invite@#{parts[:domain]}".downcase
          refuse!(prefix, account, 'invite_email_format') unless email&.match?(EMAIL_FORMAT)

          email
        end

        # AgentBuilder#find_or_create_user と #create_account_user のうち、新しい利用者を作る側(既にいる利用者は上で止める)。仮パスワードは
        # AgentBuilder と同じ形の乱数で、どこにも出さない(招待先は PUT /auth/password でパスワードを設定する)。確認の通知を止めて
        # 保存し(確認メールを送らない)、招待メールの送信(send_confirmation_instructions)と送信枠の予約は行わない。
        def create_invitee!(account, owner, email)
          password = "1!aA#{SecureRandom.alphanumeric(12)}"
          invitee = User.new(email: email, name: INVITEE_NAME, password: password, password_confirmation: password)
          invitee.skip_confirmation_notification!
          invitee.save!
          AccountUser.create!(account: account, user: invitee, role: :agent, inviter: owner)
          invitee
        end

        # 進めないときの 1 行で abort する(transaction の中なら rollback する)。reason は固定の語([a-z_])で、入力の値・メールアドレスは
        # 出さない。
        def refuse!(prefix, account, reason)
          abort "TOYBACO_E2E_INVITE prefix=#{prefix} result=refused account=#{account&.id || LegalConsentsReport::NONE} reason=#{reason}"
        end
      end

      # toybaco:e2e_preflight[names]。staging の同意 E2E の one-shot が後段で呼ぶ rake が image にあるかと、出力行の契約の版を、読み取り
      # だけで先に確かめる。DB へは書かない(監査行は RakeAudit が書く)。名前は . で区切った 1〜20 個(各 toybaco: の下の task の名前の形。
      # E2E の task は e2e_ で数字を含む)。各名前を Rake::Task.task_defined? で順に調べ、出力行の契約の版(RAKE_CONTRACT)と、全てあれば
      # ready、欠けていれば missing と最初に欠けた名前を 1 行で出す(どちらも正常に終わる)。名前の形が違えば(数が 0 か 21 以上も)refused の
      # 1 行で abort する。入力の値は出さない。
      module Preflight
        NAME_FORMAT = /\A[a-z][a-z0-9_]{0,39}\z/
        LIMIT = 20
        LABEL = 'TOYBACO_E2E_PREFLIGHT'

        module_function

        def call(args)
          staging!('e2e_preflight')
          names = names!(args)
          missing = names.find { |name| !Rake::Task.task_defined?("toybaco:#{name}") }
          "#{LABEL} contract=#{RAKE_CONTRACT} result=#{missing ? 'missing' : 'ready'} missing=#{missing || LegalConsentsReport::NONE}"
        end

        # 検査と代入を同じ判定にする(通すのは . 区切りの名前の文字列 1 つだけで、Symbol・空の名前・余分な引数は通さない)。
        def names!(args)
          raw = args[:names]
          names = raw.is_a?(String) ? raw.split('.', -1) : []
          unless names.size.between?(1, LIMIT) && names.all? { |name| name.match?(NAME_FORMAT) }
            abort "#{LABEL} contract=#{RAKE_CONTRACT} result=refused missing=#{LegalConsentsReport::NONE} reason=name_format"
          end
          abort '引数は names の 1 つだけを指定してください。' unless args.extras.empty?

          names
        end

        def staging!(task)
          E2eConsent.staging!(task)
        end
      end

      # 無料登録の段階。記録が無ければ -、形に合わない値は中身を出さずに invalid と出す。
      def phase(account)
        state = Toybaco::Entitlements.attributes(account)[Toybaco::Growth::FreeRegistration::KEY]
        value = state.is_a?(Hash) ? state['phase'] : nil
        return LegalConsentsReport::NONE if value.nil?

        value.is_a?(String) && value.match?(PHASE_FORMAT) ? value : 'invalid'
      end

      # toybaco:e2e_purge_accounts[prefix]。名前が prefix で始まる店舗(一致集合)のうち id の順の先頭 5 件(バッチ)と、その店舗にだけ所属する
      # E2E 用の利用者を削除し、残りの件数(remaining)を出す。一致が 5 件を超えても abort せず、残りは次の呼び出しで消す(前回までの run の
      # 残骸が溜まっても繰り返せば減らせる)。利用者・契約者は、範囲を一致集合で、消すかどうかをバッチで判定する。一致集合の外にも所属する
      # 契約者がいれば abort し、一致集合には閉じるがバッチの外の一致した店舗にも所属する利用者・契約者は消さずに数え、所属がバッチに閉じた
      # 回に消す(同じ利用者が 6 件以上の一致した店舗に所属しても、毎回同じ先頭 5 件で止まらない)。範囲の安全は、全ての一致が E2E の店舗名の
      # 厳格な形であること(1 件でも違えば何も消さない。transaction の中でも全ての一致を行ロックして確かめ直す)と、利用者・契約者の検査で
      # 守る。削除の手順は Purge にある。店舗を消した後に、店舗に FK を持たない体験と自動応答の記録(Purge::GrowthRecords)のうち、
      # 消した店舗の id のものも同じ transaction で消し、件数を TOYBACO_E2E_PURGE の次の 1 行(TOYBACO_E2E_PURGE_GROWTH)に出す
      # (TOYBACO_E2E_PURGE の行の形は変えない)。店舗を消す前に、バッチの店舗の購入と契約の id に結ばれた課金の記録の残り(終端の event と、
      # 止まった同期の依頼。Purge::BillingRecords)も同じ transaction で消し、件数を GROWTH の次の 1 行(TOYBACO_E2E_PURGE_BILLING)に出す。
      # 続けて、e2e_opening_checkout が作った開通の受付の記録のうち、合成 id が prefix の英数字で始まる厳格な形のもの(Purge::OpeningRecords)も
      # 同じ transaction で消し、件数をその次の 1 行(TOYBACO_E2E_PURGE_OPENING。最後の行)に出す。
      def purge(args)
        staging!('e2e_purge_accounts')
        prefix = prefix!(args)
        stores = run_names!(prefix, accounts(prefix), '削除')
        Purge.run(prefix, stores)
      end

      # prefix に一致した店舗が全て E2E の run ごとの店舗名(RUN_NAME_FORMAT)であること。1 件でも違えば何もせずに abort する。
      def run_names!(prefix, stores, action)
        others = stores.count { |store| !store.name.match?(RUN_NAME_FORMAT) }
        return stores if others.zero?

        abort "prefix=#{prefix} に一致する店舗に、E2E の店舗名の形(e2e-consent-r<run>-<attempt>)でない店舗が #{others} 件あるため#{action}しません。"
      end

      # 1 回に確認する店舗は 5 件まで。超えるときは 1 件も扱わない(prefix の打ち間違いで広く書き換えない)。削除は先頭 5 件だけを消す。
      def within_limit!(prefix, stores, label, action)
        return stores if stores.size <= PURGE_LIMIT

        abort "prefix=#{prefix} に一致する#{label}が #{stores.size} 件あり、1 回の上限 #{PURGE_LIMIT} 件を超えるため#{action}しません。prefix を絞ってください。"
      end

      # 書き込みの 2 本(確認・削除)の transaction の守り。選んだ店舗の行ロックと読み直しと、削除の transaction の中で積まれる job の commit 後送り。
      module WriteGuard
        module_function

        # transaction の中で、選んだ店舗を id の順に行ロックして読み直し、名前(prefix と厳格な形)とブロックの条件を確かめ直す。選んだ後に
        # 別の接続が名前や状態を変えていれば、何も書かずに abort する(ロックの後は commit まで変えられない)。厳格な形は既定で E2E の run
        # ごとの店舗名(RUN_NAME_FORMAT)。目視用の店舗の削除(E2eVisual)は、その店舗名の形(E2eVisual::NAME_FORMAT)を渡す。
        def relock!(prefix, stores, action, name_format: RUN_NAME_FORMAT)
          stores.sort_by(&:id).each do |store|
            store.reload(lock: true)
            next if store.name.start_with?(prefix) && store.name.match?(name_format) && (!block_given? || yield(store))

            abort "account=#{store.id} の名前か状態が選んだ後に変わったため#{action}しません。"
          end
        end

        # transaction の中で積まれる job(所属の削除の Agents::DestroyJob・destroy_async の削除・イベントの配信)を commit の後に送り、
        # rollback なら捨てる。この app は load_defaults 7.0 で ActiveJob::Base.enqueue_after_transaction_commit が :never のため、
        # rake の処理の間だけ :always にして戻す(rake は one-shot の process で走る。job クラスが個別に持つ値はそのまま)。rollback の後に
        # overlay の after_rollback が積む戻しの job(PostizMembershipJob)は transaction の外なので、そのまま送られる。
        def jobs_after_commit
          previous = ActiveJob::Base.enqueue_after_transaction_commit
          ActiveJob::Base.enqueue_after_transaction_commit = :always
          yield
        ensure
          ActiveJob::Base.enqueue_after_transaction_commit = previous
        end
      end

      # 全体を 1 つの transaction で行う。最初に一致集合の全店舗(バッチの外も)を id の順に行ロックして読み直し、名前(prefix と厳格な形)を
      # 確かめ直す。バッチの外の一致した店舗が選んだ後に改名されていても、何も消さずに abort する(利用者・契約者の範囲は一致集合で判定する
      # ため、改名を見ずに古い一致集合を信じると、その店舗にも所属する契約者を残して先頭 5 件を消し、以後 prefix で辿れない店舗の側に契約者
      # が残る。ロックの後は commit まで改名されない)。続けて契約者(所属が既に無くても)を確かめてから、バッチの店舗を消す。
      # overlay の削除時の検査(所属の書き手・自動応答の bot)は店舗の行を読むため、店舗が残っているうちに所属・bot の割り当て・bot を同期で
      # 消し(後から動く destroy_async の job で親が見つからずに失敗しない)、利用者、店舗の順に SuperAdmin・Platform API と同じ
      # DeleteObjectJob の処理で消す。利用者は transaction の中で行ロック(所属の書き手が取るのと同じ users の行)を取って読み直し、所属が
      # バッチに閉じていれば消す。バッチの外の一致した店舗にも所属する利用者と、読み直すと条件から外れた利用者は消さずに数える(外れた 1 人の
      # ためにほかの店舗・利用者の削除を巻き戻さない。バッチの外の一致した店舗の所属は残り、所属がバッチに閉じた回に消える)。読み直して
      # 店舗・利用者・所属・bot が残っていれば abort(SystemExit)で rollback して何も消さない。その間に積まれた job は commit の後に送り、
      # rollback なら捨てる(WriteGuard.jobs_after_commit)。
      module Purge
        # 店舗が残っているうちに消す子(削除時の検査が店舗の行を読むもの)。所属は全員分(消さない利用者の所属も)、bot の割り当て、bot の順。
        CHILDREN = %w[AccountUser AgentBotInbox AgentBot].freeze

        module_function

        # matched は一致集合の店舗(run_names! を通った全ての店舗、id の順)、stores はバッチ(その先頭 5 件)。remaining は一致集合のうち
        # バッチの外の件数。候補の下見は transaction の前の id で選び、消すかどうかは transaction の中でロックした店舗で決める。
        # skipped_users は候補(所属からの候補と契約者)のうち消さなかった利用者の数(同じ利用者は 1 回)。返すのは TOYBACO_E2E_PURGE の行と、
        # 消した体験と自動応答の記録の件数の行(TOYBACO_E2E_PURGE_GROWTH)と、消した課金の記録の件数の行(TOYBACO_E2E_PURGE_BILLING)と、
        # 消した開通の受付の記録の件数の行(TOYBACO_E2E_PURGE_OPENING。staging の同意 E2E の one-shot が終端に読むので最後に置く)の 4 行。
        def run(prefix, matched)
          stores = matched.first(PURGE_LIMIT)
          found = candidates(stores.map(&:id), matched.map(&:id))
          users, kept, growth, billing, opening =
            WriteGuard.jobs_after_commit { ActiveRecord::Base.transaction { delete!(prefix, matched, stores, found) } }
          skipped = ((found + kept).map(&:id) - users.map(&:id)).uniq.size
          remaining = matched.size - stores.size
          ["TOYBACO_E2E_PURGE prefix=#{prefix} accounts=#{stores.size} users=#{users.size} skipped_users=#{skipped} remaining=#{remaining}",
           GrowthRecords.line(prefix, growth), BillingRecords.line(prefix, billing), OpeningRecords.line(prefix, opening)]
        end

        # transaction の中で呼ぶ。最初に一致集合の全店舗を行ロックして確かめ直し(バッチの店舗も同じ object が読み直される)、以後の判定と
        # 削除はロックした店舗の id で行う。消した利用者と、消さずに残す契約者と、消した体験と自動応答の記録の件数と、消した課金の記録と、
        # 消した開通の受付の記録の件数を返す。契約者は所属から選んだ候補とは別に、確かめた上で消す集合に入れる(所属が既に無い契約者も残さない)。
        # 課金の記録は、契約者を確かめた後・店舗を消す前に、ロックした店舗の購入と契約の id で選んで消す(BillingRecords)。体験と自動応答の
        # 記録は、店舗を消す前に控えたバッチの id(全ての一致が E2E の店舗名の厳格な形で、ロックして確かめ直した店舗)のものだけを、店舗を
        # 消した後に消す。開通の受付の記録は prefix の英数字で始まる合成 id の形で選び、店舗に結んだ行はバッチの店舗のものだけを消す
        # (OpeningRecords)。
        def delete!(prefix, matched, stores, found)
          WriteGuard.relock!(prefix, matched, '削除')
          ids = stores.map(&:id)
          removable, kept = owners!(stores, ids, matched.map(&:id))
          eligible = (removable + found.select { |user| locked_eligible?(user, ids) }).uniq(&:id)
          billing = BillingRecords.delete!(prefix, stores)
          children!(ids)
          (eligible + stores).each { |record| DeleteObjectJob.new.perform(record) }
          growth = GrowthRecords.delete!(ids)
          opening = OpeningRecords.delete!(prefix, ids)
          verify_deleted!(prefix, ids, eligible, billing)
          [eligible, kept, growth, billing, opening]
        end

        # 削除を読み直し、店舗・利用者・所属・bot・体験と自動応答の記録か、消した課金の記録(消した id で読み直す。処理中の行を並行の worker が
        # 終端にしても偽の取り消しにならない)か、開通の受付の記録が残っていれば abort(SystemExit)で rollback する。
        def verify_deleted!(prefix, account_ids, users, billing)
          abort "prefix=#{prefix} の削除を読み直すと店舗・利用者・所属・bot・体験と自動応答の記録が残っているため、削除を取り消します。" if remaining?(account_ids, users)
          abort "prefix=#{prefix} の削除を読み直すと課金の記録(終端の event・同期の依頼)が残っているため、削除を取り消します。" if BillingRecords.remaining?(billing)
          return unless OpeningRecords.remaining?(prefix, account_ids)

          abort "prefix=#{prefix} の削除を読み直すと開通の受付の記録が残っているため、削除を取り消します。"
        end

        # 店舗の契約者(無料登録の owner)を行ロックして読み直し、消す契約者(所属がバッチに閉じる)と残す契約者(一致集合には閉じるが、
        # バッチの外の一致した店舗にも所属する)に分けて返す。E2E の利用者でないか一致集合の外にも所属する契約者がいれば、店舗を消す前に
        # abort する(非 E2E の利用者や実店舗の利用者を巻き込まない。その契約者を数えて進めると、契約者の店舗だけが消えて固定メールの利用者が
        # 残り、次の run の登録が 409 になる)。残す契約者は消さずに数える。その所属が残る一致した店舗は remaining に数えられるため呼び出し側は
        # 続けて呼び、所属がバッチに閉じた回に契約者も消える(バッチの外の所属で毎回 abort して進まなくならない)。契約者が既に無い店舗は
        # そのまま消す。
        def owners!(stores, batch_ids, matched_ids)
          owners = stores.filter_map do |store|
            state = Toybaco::Entitlements.attributes(store)[Toybaco::Growth::FreeRegistration::KEY]
            owner = state.is_a?(Hash) ? User.find_by(id: state['owner_id']) : nil
            next if owner.nil?
            next owner if e2e_scope?(owner.reload(lock: true), matched_ids)

            abort "account=#{store.id} の契約者 user=#{owner.id} が E2E の利用者でないか、ほかの店舗にも所属するため削除しません。"
          end
          owners.partition { |owner| eligible_user?(owner, batch_ids) }
        end

        # バッチの店舗に所属する利用者のうち、所属が一致集合に閉じる E2E の利用者(transaction の前の下見。transaction の中でロックして
        # 読み直し、所属がバッチに閉じていれば消し、そうでなければ消さずに数える)。一致集合の外にも所属する利用者は候補にしない(バッチの
        # 店舗の所属だけが消える)。id の順。
        def candidates(batch_ids, matched_ids)
          ids = AccountUser.where(account_id: batch_ids).distinct.pluck(:user_id)
          User.where(id: ids).order(:id).select { |user| e2e_scope?(user, matched_ids) }
        end

        # 候補を行ロックして読み直し、まだ消してよいか。ロックの前に消えていた利用者は消さない側に数える。
        def locked_eligible?(user, batch_ids)
          eligible_user?(user.reload(lock: true), batch_ids)
        rescue ActiveRecord::RecordNotFound
          false
        end

        # E2E の利用者で、所属が account_ids の店舗の外に無い: SuperAdmin(type あり)でなく、E2E 用のメールアドレスで、ほかの店舗に所属しない。
        # 一致集合の id で確かめて、候補と契約者の範囲にする。
        def e2e_scope?(user, account_ids)
          user.type.blank? && user.email.to_s.match?(EMAIL_FORMAT) && !AccountUser.where(user_id: user.id).where.not(account_id: account_ids).exists?
        end

        # 消してよい利用者: バッチの id で確かめた e2e_scope?(所属がバッチの店舗に閉じる)。バッチは一致集合の一部なので、範囲の内側でもある。
        def eligible_user?(user, batch_ids)
          e2e_scope?(user, batch_ids)
        end

        def children!(account_ids)
          CHILDREN.each { |name| name.constantize.where(account_id: account_ids).order(:id).each(&:destroy!) }
        end

        def remaining?(account_ids, users)
          Account.exists?(id: account_ids) || User.exists?(id: users.map(&:id)) ||
            CHILDREN.any? { |name| name.constantize.exists?(account_id: account_ids) } || GrowthRecords.remaining?(account_ids)
        end

        # 店舗に FK を持たない体験(toybaco_growth_trials と、trial_id で結ぶ toybaco_growth_trial_identities)と自動応答
        # (toybaco_growth_auto_installations / commands / requests)の記録。本番では店舗を消しても残す(同じ接続先・店舗での体験の再発行を
        # 防ぐ)が、E2E の店舗の記録は run ごとに溜まり、次の run の体験が同じ形の identity で断られうるため、消した店舗の分だけ消す。
        # 店舗の id の集合は Purge が E2E の店舗名の厳格な形で確かめたバッチだけ(ほかの店舗の記録には触れない)。identity は体験への FK が
        # あるので先に消す(体験の通知は体験と店舗への FK の on_delete cascade で消える)。検証もコールバックも通さない(delete_all)。
        module GrowthRecords
          module_function

          def delete!(account_ids)
            trials = Toybaco::GrowthTrial.where(account_id: account_ids)
            identities = Toybaco::GrowthTrialIdentity.where(trial_id: trials.select(:id)).delete_all
            Toybaco::GrowthAutoRequest.where(account_id: account_ids).delete_all
            Toybaco::GrowthAutoCommand.where(account_id: account_ids).delete_all
            { 'trials' => trials.delete_all, 'identities' => identities,
              'installations' => Toybaco::GrowthAutoInstallation.where(account_id: account_ids).delete_all }
          end

          def remaining?(account_ids)
            [Toybaco::GrowthTrial, Toybaco::GrowthAutoInstallation, Toybaco::GrowthAutoCommand, Toybaco::GrowthAutoRequest]
              .any? { |model| model.exists?(account_id: account_ids) }
          end

          def line(prefix, counts)
            "TOYBACO_E2E_PURGE_GROWTH prefix=#{prefix} trials=#{counts.fetch('trials')} identities=#{counts.fetch('identities')} " \
              "installations=#{counts.fetch('installations')}"
          end
        end

        # 店舗に FK を持たない課金の記録(toybaco_billing_events と toybaco_subscription_sync_requests)のうち、E2E の購読の残り。残すと毎分の
        # sweep が TOYBACO_BILLING_ATTENTION / TOYBACO_SUBSCRIPTION_SYNC_ATTENTION を出し続ける。対象の id はロックしたバッチの店舗(全ての一致が
        # E2E の店舗名の厳格な形)の購入の記録の Session と、契約の購読と、その店舗に結ばれた同期の依頼の購読(形の合う値だけ。
        # GrowthLive::Cancel の後片付けと同じ検査)。消すのは test mode で終端(completed・attention)の event のうち、更新の請求書の記録と開通の
        # 受付に結ばれていないもの、続けてその購読の依頼のうち店舗に結ばれていない(account_id が NULL の)ものと、バッチの店舗に結ばれた
        # attention のもの(event から FK で参照されていれば残す)。処理中の event(pending・queued・processing)と依頼(pending・running)、
        # 店舗に結ばれた completed・superseded の依頼(遅れた通知の墓標。消すと次の通知が NULL の依頼を作り直し、24 時間後に attention になる)、
        # live mode の行、ほかの店舗に結ばれた依頼には触れない。処理中の行は消さずに数える(inflight)。行ロックしてから id を控えて消し、
        # 消した id を返す(読み直しは消した id で行う)。DB の失敗は例外の文を出さずに固定の文で止める(rollback。billing_failed)。
        module BillingRecords
          TERMINAL = %w[completed attention].freeze
          INFLIGHT = %w[pending queued processing].freeze
          RUNNING = %w[pending running].freeze

          module_function

          # transaction の中で、店舗を消す前に呼ぶ。消した event と依頼の id と、消さずに数えた処理中の行の数を返す。
          def delete!(prefix, stores)
            references = references(stores)
            subscriptions = references.grep(E2eBilling::GrowthLive::SUBSCRIPTION_FORMAT)
            events = remove!(removable_events(references))
            requests = remove!(removable_requests(subscriptions, stores.map(&:id)))
            { 'events' => events, 'requests' => requests, 'inflight' => inflight(references, subscriptions) }
          rescue ActiveRecord::ActiveRecordError
            E2eBilling::GrowthLive.stop!("prefix=#{prefix} の課金の記録(終端の event・同期の依頼)を DB の失敗で消せないため、削除を取り消します。")
          end

          # 店舗の購入の記録の Session・契約の購読と、店舗に結ばれた同期の依頼の購読(形の合う値だけ、重複なし)。
          def references(stores)
            require Rails.root.join('lib/toybaco/growth/purchase_intent').to_s
            values = stores.flat_map do |store|
              session = Toybaco::Growth::PurchaseIntent.saved(store)&.fetch('session_id', nil)
              [session, Toybaco::Entitlements.attributes(store)['toybaco_subscription_id']]
            end
            values += Toybaco::SubscriptionSyncRequest.where(mode: E2eBilling::MODE, account_id: stores.map(&:id)).pluck(:subscription_id)
            live = E2eBilling::GrowthLive
            values.select { |value| value.to_s.match?(live::SESSION_FORMAT) || value.to_s.match?(live::SUBSCRIPTION_FORMAT) }.uniq
          end

          def removable_events(references)
            Toybaco::BillingEvent.where(mode: E2eBilling::MODE, state: TERMINAL, reference_id: references, opening_request_id: nil)
                                 .where.not(id: facts)
          end

          def removable_requests(subscriptions, account_ids)
            scope = Toybaco::SubscriptionSyncRequest.where(mode: E2eBilling::MODE, subscription_id: subscriptions).where.not(state: RUNNING)
            scope.where(account_id: nil).or(scope.where(account_id: account_ids, state: 'attention')).where.not(id: bound)
          end

          # 更新の請求書の記録(取り消せない証跡)が結ぶ event。
          def facts
            Toybaco::RenewalInvoiceFact.where.not(billing_event_id: nil).select(:billing_event_id)
          end

          # event から FK で参照されている同期の依頼。
          def bound
            Toybaco::BillingEvent.where.not(subscription_sync_request_id: nil).select(:subscription_sync_request_id)
          end

          # 行ロックしてから id を控えて消し、消した id を返す。
          def remove!(scope)
            ids = scope.lock.pluck(:id)
            scope.klass.where(id: ids).delete_all
            ids
          end

          def inflight(references, subscriptions)
            Toybaco::BillingEvent.where(mode: E2eBilling::MODE, state: INFLIGHT, reference_id: references).count +
              Toybaco::SubscriptionSyncRequest.where(mode: E2eBilling::MODE, state: RUNNING, subscription_id: subscriptions).count
          end

          def remaining?(deleted)
            Toybaco::BillingEvent.exists?(id: deleted.fetch('events')) || Toybaco::SubscriptionSyncRequest.exists?(id: deleted.fetch('requests'))
          end

          def line(prefix, deleted)
            "TOYBACO_E2E_PURGE_BILLING prefix=#{prefix} events=#{deleted.fetch('events').size} requests=#{deleted.fetch('requests').size} " \
              "inflight=#{deleted.fetch('inflight')}"
          end
        end

        # 店舗に FK を持たない開通の受付の記録(toybaco_opening_requests と、opening_request_id で結ぶ toybaco_billing_events・
        # toybaco_opening_notices)。e2e_opening_checkout が作る合成 id(Session cs_test_<tag>o・event evt_<tag>o。tag は run の prefix の
        # - を x に写した英数字。E2eBilling.tag)の形の test mode の行だけを消す。選び方は prefix を同じく写した stem の前方一致と厳格な形
        # (cs_test_<stem>[0-9x]*o / evt_<stem>[0-9x]*o)で、run の prefix(e2e-consent-r<run>-<attempt>)でも、前回までの残骸を消す族の prefix
        # (e2e-consent-r。stem は e2exconsentxr)でも、その範囲の run の行に当たる。この形の id は E2E の run の合成 id だけが持つ(Stripe の実 id
        # は cs_test_ / evt_ の後ろが英大文字・小文字・数字の混ざった並びで、stem・数字・x・o だけの形にならない)。前方一致で別の run の
        # 行に当たっても、それは E2E の run が作った行なので消してよい。店舗の id の集合だけでは選ばない(E2E 以外の開通の受付には触れない)。
        # 開通に失敗して店舗の無い受付(pending / attention、account_id は NULL)も合成 id の形で拾い、店舗に結んだ受付はバッチの店舗
        # (消した店舗)のものだけを消す。event はその受付に結んだものと、受付に結ぶ前の合成 id の形のものを消し、案内はその受付に結んだものを
        # 消す。FK の順(notices → events → requests)に、検証もコールバックも通さずに消す(delete_all)。durable の trigger は INSERT /
        # UPDATE を記録するだけで、元の表の DELETE は禁じない(受入の記録は残る)。
        module OpeningRecords
          module_function

          def delete!(prefix, account_ids)
            ids = request_ids(prefix, account_ids)
            notices = Toybaco::OpeningNotice.where(opening_request_id: ids).delete_all
            events = Toybaco::BillingEvent.where(id: event_ids(prefix, ids)).delete_all
            { 'requests' => Toybaco::OpeningRequest.where(id: ids).delete_all, 'events' => events, 'notices' => notices }
          end

          # 合成 id の形の開通の受付(店舗の無いものと、バッチの店舗に結んだもの)。DB で前方一致に絞り、Ruby で厳格な形を確かめる。
          def request_ids(prefix, account_ids)
            scope = Toybaco::OpeningRequest.where(mode: E2eBilling::MODE, account_id: [nil, *account_ids])
            synthetic(scope, :session_id, 'cs_test_', prefix)
          end

          # その受付に結んだ event と、受付に結ぶ前(opening_request_id が NULL)の合成 id の形の event。
          def event_ids(prefix, request_ids)
            scope = Toybaco::BillingEvent.where(mode: E2eBilling::MODE)
            scope.where(opening_request_id: request_ids).pluck(:id) | synthetic(scope.where(opening_request_id: nil), :event_id, 'evt_', prefix)
          end

          def synthetic(scope, column, head, prefix)
            stem = E2eBilling.tag(prefix, '')
            format = /\A#{head}#{Regexp.escape(stem)}[0-9x]*#{E2eBilling::OpeningSeam::SUFFIX}\z/
            like = scope.klass.arel_table[column].matches("#{head}#{ActiveRecord::Base.sanitize_sql_like(stem)}%", nil, true)
            scope.where(like).pluck(:id, column).filter_map { |id, value| id if value.match?(format) }
          end

          def remaining?(prefix, account_ids)
            request_ids(prefix, account_ids).any? || event_ids(prefix, []).any?
          end

          def line(prefix, counts)
            "TOYBACO_E2E_PURGE_OPENING prefix=#{prefix} requests=#{counts.fetch('requests')} events=#{counts.fetch('events')} " \
              "notices=#{counts.fetch('notices')}"
          end
        end
      end
    end
  end
end

namespace :toybaco do
  desc '名前が prefix で始まる E2E の店舗の規約同意の記録を読み取りだけで表示する(rake "toybaco:legal_consents_by_name[e2e-consent-<run>]")'
  task :legal_consents_by_name, %i[prefix] => :environment do |_t, args|
    Toybaco::Ops::E2eConsent.consents_by_name(args).each { |line| puts line }
  end

  desc 'staging 専用: 名前が prefix で始まる E2E の店舗(メール確認待ち、1 回 5 件まで)の契約者を確認し、無料登録を有効にする' \
       '(rake "toybaco:e2e_confirm_user[e2e-consent-<run>]")'
  task :e2e_confirm_user, %i[prefix] => :environment do |_t, args|
    Toybaco::Ops::E2eConsent.confirm(args).each { |line| puts line }
  end

  # ops-rake workflow の allowlist には入れない(引数に確認 token(秘密)を取り、workflow の入力と run の記録に残るため)。
  desc 'staging 専用: 名前が prefix で始まる E2E の店舗(メール確認待ち、ちょうど 1 件)の未確認の契約者に、runner が作った確認 token' \
       '(英小文字の 16 進数 64 桁)を設定する。token は出力しない(rake "toybaco:e2e_confirmation_token[e2e-consent-<run>,<token>]")'
  task :e2e_confirmation_token, %i[prefix token] => :environment do |_t, args|
    puts Toybaco::Ops::E2eConsent::Confirmation.confirmation_token(args)
  end

  desc 'staging 専用: 名前が prefix で始まる E2E の店舗ごとに、無料登録の契約者・段階・契約者の確認の有無を読み取りだけで表示する' \
       '(rake "toybaco:e2e_registration_phase[e2e-consent-<run>]")'
  task :e2e_registration_phase, %i[prefix] => :environment do |_t, args|
    Toybaco::Ops::E2eConsent::Confirmation.registration_phase(args).each { |line| puts line }
  end

  # ops-rake workflow の allowlist には入れない(引数にパスワード再設定 token(秘密)を取り、workflow の入力と run の記録に残るため)。
  desc 'staging 専用: 名前が prefix で始まる E2E の店舗(有効、ちょうど 1 件)に、E2E 用のメールアドレスの未確認の担当者を招待メールを送らずに作り、' \
       'runner が作ったパスワード再設定 token(英小文字の 16 進数 64 桁)の digest を設定する。token は出力しない' \
       '(rake "toybaco:e2e_invite_agent[e2e-consent-<run>,<token>]")'
  task :e2e_invite_agent, %i[prefix token] => :environment do |_t, args|
    puts Toybaco::Ops::E2eConsent::Invitation.invite_agent(args)
  end

  desc 'staging 専用: 名前が prefix で始まる E2E の店舗(id の順に 1 回 5 件まで。残りの件数を出す)と、その店舗だけの利用者と、' \
       'その店舗の体験・自動応答の記録を削除する(rake "toybaco:e2e_purge_accounts[e2e-consent-<run>]")'
  task :e2e_purge_accounts, %i[prefix] => :environment do |_t, args|
    puts Toybaco::Ops::E2eConsent.purge(args)
  end
end

namespace :toybaco do
  desc 'staging 専用: E2E の rake が image にあるかを読み取りだけで調べ、出力行の契約の版と最初に欠けた名前を表示する' \
       '(rake "toybaco:e2e_preflight[e2e_purge_accounts.e2e_growth_cancel]"。名前は . で区切って 1〜20 個)'
  task :e2e_preflight, %i[names] => :environment do |_t, args|
    puts Toybaco::Ops::E2eConsent::Preflight.call(args)
  end
end

# staging の E2E(規約同意の記録の経路の確認)のうち、Stripe を使わない 2 経路(体験の開始 trial と、おまかせ自動返信の開始 managed_auto)用。
# 無料登録の E2E で有効にした店舗に対し、本番の開始処理(Growth::TrialStart#start! と、Growth::ManagedAutoInstall の create! → change!)を
# 契約者として呼び、規約同意の記録(route trial / managed_auto)を残す。本番の処理は変えず、その前提だけを rake の中で作る。外部には
# 接続しない: IMAP の実ログインは ImapVerification の成功の記録(今の設定の指紋と時刻)を先に書いて起こさず、回答例は LLM を呼ばずに bot の
# 結果の受け口(Growth::BotReply の reserve → consumed)に固定の本文で作り、Stripe・SES・Postiz の経路は通らない。受信箱のホストとアドレスは
# 名前解決されない予約ドメイン(.invalid、RFC 6761)にする。2 本とも引数は E2E の店舗名の prefix だけで、一致する店舗が E2E の店舗名の
# 厳格な形でちょうど 1 件・有効、契約者(無料登録の owner)が E2E の利用者で確認済みの管理者のときだけ進む。環境の判定と prefix の形は
# E2eConsent と同じ(staging 以外は引数を読む前に abort。ops-rake workflow も e2e_ で始まるタスクを staging 以外で拒否する二重の
# fail-closed)。出力は TOYBACO_E2E_TRIAL / TOYBACO_E2E_MANAGED_AUTO の 1 行(result・店舗の id・reason)だけで、メールアドレス・
# パスワード・鍵・氏名は出さない。進めないとき(refused と、機能フラグが off の skipped)は同じ形の 1 行で abort する(非 0 で終わり、監査行は
# failed)。同じ prefix の 2 回目は何も書かずに skipped(already_done)で正常に終わる。監査行(started / ok|failed)は上の RakeAudit が
# 書く。rake は Rails の初期化前にこのファイルを読むため、モデルとサービスは実行時に参照する。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    module E2eGrowth
      TRIAL = 'TRIAL'
      MANAGED_AUTO = 'MANAGED_AUTO'
      NONE = '-'

      module_function

      def staging!(task)
        E2eConsent.staging!(task)
      end

      # 本番の開始処理と回答例の受け口と、購入の記録(AutoSeam が Standard の購入を確かめる)。rake では controller(画面)が読まれない
      # ため、ここで読む(読み済みなら何もしない)。
      def require_growth!
        %w[trial_start bot_reply managed_auto_install purchase_intent].each { |name| require Rails.root.join("lib/toybaco/growth/#{name}").to_s }
      end

      # toybaco:e2e_trial[prefix]。体験の前提(店舗情報・IMAP の受信箱と bot・回答例)を作ってから体験を開始する(TrialSeam)。
      # 体験が既にあれば何も書かずに skipped。
      def trial(args)
        staging!('e2e_trial')
        require_growth!
        prefix = E2eConsent.prefix!(args)
        account, owner = target!(TRIAL, prefix)
        return line(TRIAL, 'skipped', account.id, 'already_done') if Toybaco::GrowthTrial.exists?(account_id: account.id)

        TrialSeam.start!(prefix, account, owner)
        line(TRIAL, 'started', account.id, NONE)
      end

      # toybaco:e2e_managed_auto[prefix]。体験の後の店舗を Standard にし、体験の bot を外して、おまかせ自動返信を全自動で開始する
      # (AutoSeam)。全自動の設置と同意の記録が既にあれば何も書かずに skipped。機能フラグ(ManagedAuto.enabled?)が off なら、何も書かずに
      # skipped(flag_off)で abort する。前の実行が設置の後の切り替えで止まっていれば、切り替えから再開する。
      def managed_auto(args)
        staging!('e2e_managed_auto')
        require_growth!
        prefix = E2eConsent.prefix!(args)
        account, owner = target!(MANAGED_AUTO, prefix)
        return line(MANAGED_AUTO, 'skipped', account.id, 'already_done') if AutoSeam.installed?(account)

        refuse!(MANAGED_AUTO, account.id, 'flag_off', result: 'skipped') unless Toybaco::Growth::ManagedAuto.enabled?

        AutoSeam.install!(prefix, account, owner)
        line(MANAGED_AUTO, 'installed', account.id, NONE)
      end

      # 対象の店舗と契約者。prefix に一致する店舗が全て E2E の店舗名の厳格な形で、ちょうど 1 件のときだけ。
      def target!(label, prefix)
        stores = E2eConsent.accounts(prefix)
        refuse!(label, nil, 'name_format') unless stores.all? { |store| store.name.match?(E2eConsent::RUN_NAME_FORMAT) }
        refuse!(label, nil, stores.empty? ? 'no_account' : 'multiple_accounts') unless stores.size == 1

        [stores.first, owner!(label, stores.first)]
      end

      # 有効な店舗の契約者(無料登録の owner)。E2E の利用者(E2eConsent.e2e_user?)で、店舗の管理者で、メール確認済みであること。
      def owner!(label, account)
        refuse!(label, account.id, 'account_inactive') unless account.active?
        state = Toybaco::Entitlements.attributes(account)[Toybaco::Growth::FreeRegistration::KEY]
        owner = state.is_a?(Hash) ? User.find_by(id: state['owner_id']) : nil
        refuse!(label, account.id, 'owner_missing') unless owner
        administrator = account.account_users.exists?(user_id: owner.id, role: :administrator)
        refuse!(label, account.id, 'owner_not_e2e') unless E2eConsent.e2e_user?(owner) && administrator
        refuse!(label, account.id, 'owner_unconfirmed') unless owner.confirmed?
        owner
      end

      # transaction の中で、店舗を行ロックして読み直し、名前(prefix と厳格な形)と有効なことを確かめ直す。
      def relock!(label, prefix, account)
        account.lock!
        return if account.name.start_with?(prefix) && account.name.match?(E2eConsent::RUN_NAME_FORMAT) && account.active?

        refuse!(label, account.id, 'account_changed')
      end

      def line(label, result, account_id, reason)
        "TOYBACO_E2E_#{label} result=#{result} account=#{account_id || NONE} reason=#{reason}"
      end

      # 進めないときの 1 行で abort する(transaction の中なら rollback する)。
      def refuse!(label, account_id, reason, result: 'refused')
        abort line(label, result, account_id, reason)
      end

      # 体験の前提を作って開始する。前提の作成から TrialStart#start! と結果の読み直しまでを 1 つの transaction で行い、その間に積まれる
      # job は commit の後に送る(E2eConsent::WriteGuard.jobs_after_commit)。断られたら(TrialStart::Unavailable)前提も残さずに
      # TrialStart::MESSAGES のキーを reason に出す。受信箱は commit まで上流の IMAP の fetch job から見えない。
      module TrialSeam
        # 受信箱の IMAP の設定。.invalid は名前解決されないので、上流の fetch job が接続を試みても外に出ない。gmail.com のアドレスは使わない
        # (TrialConnection は imap.gmail.com 以外のホストの Gmail のアドレスを対象外にする)。アドレスとログインは店舗名(run ごとに違う)で作る。
        DOMAIN = 'e2e-imap.invalid'
        HOST = "imap.#{DOMAIN}".freeze
        PORT = 993
        # 固定のダミー(どこにもログインしない。ImapVerification の指紋の材料になるだけ)。
        PASSWORD = 'e2e-imap-dummy-password'
        BOT_NAME = 'E2E 体験 AI'
        HOURS = '10時から18時'
        QUESTION = '営業時間を教えてください。'
        REPLY = '10時から18時まで営業しています。'

        module_function

        def address(account)
          "#{account.name}@#{DOMAIN}"
        end

        # TrialStart#start! は店舗の全ての受信箱の identity を確かめ、IMAP の受信箱は成功の記録が無ければ実際にログインする。ほかの IMAP の
        # 受信箱が既にある店舗では、接続しないことを保てないので前提を作らずに断る(other_mail_inbox)。
        def start!(prefix, account, owner)
          E2eConsent::WriteGuard.jobs_after_commit do
            ActiveRecord::Base.transaction do
              E2eGrowth.relock!(TRIAL, prefix, account)
              E2eGrowth.refuse!(TRIAL, account.id, 'other_mail_inbox') if Channel::Email.exists?(account_id: account.id, imap_enabled: true)
              example = prepare!(account, owner)
              revision = Toybaco::Growth::StoreFacts.new(account).read['revision']
              Toybaco::Growth::TrialStart.new(account, owner).start!(example_id: example.id, revision: revision, confirmed: true)
              verify!(account)
            end
          end
        rescue Toybaco::Growth::TrialStart::Unavailable => e
          E2eGrowth.refuse!(TRIAL, account.id, reason(e.message))
        end

        # 店舗情報(店舗名と営業時間)を契約者として確認済みで保存し、返信の形を下書きにして(無料登録と同じ)、IMAP の受信箱に bot を
        # 割り当て、ログインの成功の記録を書いてから、その受信箱で回答例を作る。
        def prepare!(account, owner)
          Toybaco::Growth::StoreFacts.new(account).save!({ 'name' => account.name, 'hours' => HOURS }, user: owner)
          Toybaco::AiReplyMode.write_to!(account, Toybaco::AiReplyMode::DRAFT)
          inbox = mail_inbox!(account)
          bot = AgentBot.create!(account_id: account.id, name: BOT_NAME, outgoing_url: nil)
          AgentBotInbox.create!(account_id: account.id, inbox: inbox, agent_bot: bot, status: :active)
          verified!(inbox.channel)
          example!(account, inbox, bot)
        end

        # IMAP で受信する標準メール受信箱(SMTP は使わない)。認証方式は plain(ImapVerification が確かめられる方式)。
        def mail_inbox!(account)
          email = address(account)
          channel = Channel::Email.create!(account: account, email: email, imap_enabled: true, imap_login: email, imap_password: PASSWORD,
                                           imap_address: HOST, imap_port: PORT, imap_enable_ssl: true, imap_authentication: 'plain',
                                           smtp_enabled: false)
          account.inboxes.create!(channel: channel, name: "#{account.name} メール")
        end

        # ImapVerification の成功の記録(今の設定の指紋と、今の時刻)を、ImapVerification と同じ書き方(受信箱の最新の provider_config に
        # このキーだけを merge)で書く。TrialConnection.identity(:full) は同じ指紋の 7 日以内の成功を記録から決め、接続しない。
        def verified!(channel)
          verification = Toybaco::Growth::ImapVerification
          record = { 'fingerprint' => verification.fingerprint(verification.snapshot(channel)), 'verified_at' => Time.now.utc.iso8601 }
          verification.write_record!(channel, verification.recorded(channel).merge(record))
        end

        # 回答例: 保留中の会話の問い合わせ(incoming、source_id つき)に、bot の結果の受け口(BotReply の reserve → consumed)で固定の本文の
        # 下書きを付ける。TrialExample が確かめる操作の記録(consumed の reply_draft、result_reference、問い合わせと店舗情報の版の digest)は
        # BotReply と AiLedger が本番と同じ形で作る(店舗の AI 枠を 1 回使う)。
        def example!(account, inbox, bot)
          conversation, incoming = inquiry!(account, inbox)
          service = Toybaco::Growth::BotReply.new(account, bot: bot, conversation: conversation, message: incoming)
          reserved = service.update(action_type: 'reserve')
          E2eGrowth.refuse!(TRIAL, account.id, "example_#{reserved['reason'] || 'unreserved'}") unless reserved['result'] == 'reserved'
          settled = service.update(action_type: 'consumed', operation_id: reserved['operation_id'], token: reserved['token'],
                                   reply: REPLY, mode: 'draft')
          E2eGrowth.refuse!(TRIAL, account.id, 'example_unsettled') unless settled['result'] == 'consumed'
          account.messages.find(settled.fetch('result_reference').delete_prefix('message:'))
        end

        def inquiry!(account, inbox)
          contact = account.contacts.create!(name: 'E2E 問い合わせ', email: "guest-#{account.name}@#{DOMAIN}")
          contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: contact.email)
          conversation = account.conversations.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :pending)
          incoming = conversation.messages.create!(account_id: account.id, inbox_id: inbox.id, message_type: :incoming, private: false,
                                                   content: QUESTION, sender: contact, source_id: "<#{SecureRandom.uuid}@#{DOMAIN}>")
          [conversation, incoming]
        end

        # 開始の結果を読み直す。体験が 1 件、identity が IMAP の 1 件、route trial の同意の記録が 1 件でなければ取り消す。
        def verify!(account)
          trial = Toybaco::GrowthTrial.find_by(account_id: account.id)
          providers = trial ? trial.identities.pluck(:provider) : []
          routes = Toybaco::LegalTerms.records(account.reload).count { |record| record.is_a?(Hash) && record['route'] == 'trial' }
          E2eGrowth.refuse!(TRIAL, account.id, 'trial_unverified') unless providers == ['imap'] && routes == 1
        end

        # 断りの文から TrialStart::MESSAGES のキーを引く。開放済みの直接接続の名前を入れた文(PROVIDER_MESSAGES)は形で照らし合わせる。
        def reason(message)
          start = Toybaco::Growth::TrialStart
          key = start::MESSAGES.key(message)
          key ||= start::PROVIDER_MESSAGES.find { |_, text| message.match?(provider_pattern(text)) }&.first
          key || 'unavailable'
        end

        def provider_pattern(text)
          /\A#{Regexp.escape(text).sub(Regexp.escape('%<providers>s'), '.+')}\z/
        end
      end

      # 体験の後の店舗を Standard にし、体験の bot を外して、おまかせ自動返信を全自動で開始する。Standard の適用(toybaco:apply_plan と
      # 同じ Entitlements.snapshot_for → apply!、Stripe なし)と bot の削除は 1 つの transaction で行い、設置と全自動への切り替えは外側の
      # transaction を開かずに行う(ManagedAuto.locked が transaction の中を拒む)。設置と切り替えは別の transaction なので、設置の後に
      # 止まった実行は、同じ rake の再実行が切り替えから再開する。toybaco:e2e_growth_purchase で Standard を購入した店舗(購読あり)も
      # 受け付け、その Standard はそのまま使う(付け直さない)。
      module AutoSeam
        PLAN = 'standard'
        CYCLE = 'month'

        module_function

        # 全自動の設置と route managed_auto の同意の記録があれば済み。
        def installed?(account)
          Toybaco::GrowthAutoInstallation.find_by(account_id: account.id)&.state == 'auto' && routes(account).positive?
        end

        def routes(account)
          Toybaco::LegalTerms.records(account).count { |record| record.is_a?(Hash) && record['route'] == 'managed_auto' }
        end

        # 新しい設置は、Standard の適用と体験の bot の削除の後に create! してから change! する。この seam が作った未完了の設置(create! の
        # 後の change! が NOWAIT の競合やプロセスの停止で終わらなかったもの)があれば、create! を飛ばして change! だけを行って再開する。
        def install!(prefix, account, owner)
          inbox, pending = prerequisites!(account, owner)
          row = pending || register!(prefix, account, owner, inbox)
          switch!(account, owner, row)
          verify!(account)
        end

        # 体験(toybaco:e2e_trial)の後であること: 体験と体験の受信箱があり、店舗情報が確認済み。設置が無ければ、契約は無料プラン
        # (Stripe の契約なし)か適用済みの Standard で、bot は体験の受信箱の 1 組だけ(外すのはその 1 組だけ)。未完了の設置を再開する
        # ときは、契約が適用済みの Standard で、bot は設置の bot と体験の受信箱への割り当ての 1 組だけ(体験の bot は外し終えている)。
        # Standard は Stripe の契約なしのものか、toybaco:e2e_growth_purchase が購入したもの(purchased_standard?)に限る。体験は購入で
        # 完了(upgraded)していてもよい(trial_inbox! は体験の有無だけを見る)。体験の受信箱と、再開する設置(無ければ nil)を返す。
        def prerequisites!(account, owner)
          inbox, pending = trial_inbox!(account, owner)
          refuse!(account, 'facts_unconfirmed') unless Toybaco::Growth::StoreFacts.new(account).read['confirmed']
          refuse!(account, 'unexpected_contract') unless replaceable_contract?(account, pending)
          refuse!(account, 'other_bots') unless expected_bots?(account, inbox, pending)
          [inbox, pending]
        end

        # 体験と、体験の受信箱(toybaco:e2e_trial が店舗名で作ったもの)。設置の記録があれば、この seam が作った未完了の設置
        # (unfinished?)のときだけ再開に回し、ほかは installation_not_auto で断る。
        def trial_inbox!(account, owner)
          refuse!(account, 'trial_missing') unless Toybaco::GrowthTrial.exists?(account_id: account.id)
          inbox = Channel::Email.find_by(account_id: account.id, email: TrialSeam.address(account))&.inbox
          refuse!(account, 'inbox_missing') unless inbox
          installation = Toybaco::GrowthAutoInstallation.find_by(account_id: account.id)
          return [inbox, nil] unless installation
          return [inbox, installation] if unfinished?(installation, account, inbox, owner)

          refuse!(account, 'installation_not_auto')
        end

        # この seam が作った未完了の設置: 全自動でなく、この店舗の、体験の受信箱への、契約者による設置。
        def unfinished?(installation, account, inbox, owner)
          installation.state != 'auto' && installation.account_id == account.id && installation.inbox_id == inbox.id &&
            installation.actor_id == owner.id
        end

        # 購読(toybaco_subscription_id)のある店舗は、Standard の購入(purchased_standard?)のときだけ受け付ける。この seam の対象は
        # E2eGrowth.target! が E2E の店舗名の厳格な形(RUN_NAME_FORMAT)でちょうど 1 件の店舗に限っているため、緩めた分も E2E の店舗の外には
        # 掛からない。
        def replaceable_contract?(account, pending)
          contract = Toybaco::Entitlements.contract_for(account)
          return false if contract.nil?
          return purchased_standard?(account, contract) if Toybaco::Entitlements.attributes(account)['toybaco_subscription_id'].present?

          standard?(contract) || (pending.nil? && contract['plan_id'] == 'free')
        end

        # toybaco:e2e_growth_purchase が購入した Standard: 購入の記録(toybaco_growth_purchase)が complete で、その購読が店舗の購読と一致し、
        # 契約が同じ版の Standard。
        def purchased_standard?(account, contract)
          attrs = Toybaco::Entitlements.attributes(account)
          purchase = attrs[Toybaco::Growth::PurchaseIntent::KEY]
          purchase.is_a?(Hash) && purchase['state'] == 'complete' && purchase['subscription_id'].present? &&
            purchase['subscription_id'] == attrs['toybaco_subscription_id'] && standard?(contract)
        end

        def standard?(contract)
          contract['plan_id'] == PLAN && contract['plan_version'] == Toybaco::GrowthTerms::VERSION
        end

        # bot の割り当てが体験の受信箱の 1 件だけで、店舗の bot がその 1 つだけ(再開のときは、それが設置の bot)。新しい設置で bot を
        # 外し終えた後(再実行)は bot も割り当ても無い。
        def expected_bots?(account, inbox, pending)
          assignments = AgentBotInbox.where(account_id: account.id).to_a
          bots = AgentBot.where(account_id: account.id).pluck(:id)
          return pending.nil? && bots.empty? if assignments.empty?

          bot_id = assignments.first.agent_bot_id
          assignments.size == 1 && assignments.first.inbox_id == inbox.id && bots == [bot_id] && (pending.nil? || pending.bot_id == bot_id)
        end

        # 新しい設置: Standard の適用と体験の bot の削除の後、登録できることを確かめてから契約者として設置する(create!、画面と同じ)。
        def register!(prefix, account, owner, inbox)
          Preparation.run!(prefix, account, inbox)
          refuse!(account, 'registration_unavailable') unless Toybaco::Growth::ManagedAuto.registration_available?(account.reload)

          installing(account) { service(account, owner).create!(inbox_id: inbox.id, request_id: SecureRandom.uuid) }
        end

        # 同意つきで全自動に切り替える(change!、画面と同じ)。request_id は呼び出しごとの UUID、generation と epoch は設置の行の今の値
        # (画面は GET で返された値を送る)。
        def switch!(account, owner, row)
          row.reload
          installing(account) do
            service(account, owner).change!(mode: 'auto', generation: row.generation.to_s, epoch: row.epoch, request_id: SecureRandom.uuid,
                                            consent: true)
          end
        end

        def service(account, owner)
          Toybaco::Growth::ManagedAutoInstall.new(account.id, actor_id: owner.id)
        end

        # 外側の transaction を開かずに呼ぶ(ManagedAuto.locked が transaction の中を拒む)。断りと競合は理由を出して止める。
        def installing(account)
          yield
        rescue Toybaco::Growth::ManagedAuto::Invalid
          refuse!(account, 'install_invalid')
        rescue Toybaco::Growth::InboxRetention::Busy
          refuse!(account, 'install_busy')
        rescue Toybaco::Growth::InboxRetention::Held, Toybaco::Growth::InboxRetention::Invalid
          refuse!(account, 'install_inbox_unavailable')
        end

        # 設置の結果を読み直す。設置が全自動で、route managed_auto の同意の記録が 1 件でなければ止める。
        def verify!(account)
          auto = Toybaco::GrowthAutoInstallation.find_by(account_id: account.id)&.state == 'auto'
          refuse!(account, 'install_unverified') unless auto && routes(account.reload) == 1
        end

        def refuse!(account, reason)
          E2eGrowth.refuse!(MANAGED_AUTO, account.id, reason)
        end

        # 新しい設置の前の 1 つの transaction: 店舗を行ロックして確かめ直し、Standard を付け、体験の受信箱の bot の割り当てと bot を消す。
        module Preparation
          module_function

          def run!(prefix, account, inbox)
            E2eConsent::WriteGuard.jobs_after_commit do
              ActiveRecord::Base.transaction do
                E2eGrowth.relock!(MANAGED_AUTO, prefix, account)
                AutoSeam.refuse!(account, 'other_bots') unless AutoSeam.expected_bots?(account, inbox, nil)
                apply_standard!(account)
                remove_trial_bot!(account, inbox)
              end
            end
          end

          # toybaco:apply_plan[account_id,standard,<版>,month] と同じ実装(今の契約の追加契約を引き継いだ snapshot を Entitlements.apply! で
          # 付ける)。既に Standard(同じ版)なら付け直さない。
          def apply_standard!(account)
            old = Toybaco::Entitlements.contract_for(account)
            return if AutoSeam.standard?(old)

            terms = Toybaco::PlanCatalog.default.definition(AutoSeam::PLAN, Toybaco::GrowthTerms::VERSION)
            Toybaco::Entitlements.apply!(account, Toybaco::Entitlements.snapshot_for(terms, cycle: AutoSeam::CYCLE, addons: old.fetch('addons')))
          end

          # 体験の受信箱の bot の割り当てと、その bot を消す(ManagedAutoBoundaries は設置の無い bot の削除を拒まない)。
          def remove_trial_bot!(account, inbox)
            assignment = AgentBotInbox.find_by(account_id: account.id, inbox_id: inbox.id)
            return unless assignment

            bot = AgentBot.find_by(id: assignment.agent_bot_id, account_id: account.id)
            assignment.destroy!
            bot&.destroy!
          end
        end
      end
    end
  end
end

namespace :toybaco do
  desc 'staging 専用: 名前が prefix で始まる E2E の店舗(ちょうど 1 件)に、体験の前提(店舗情報・IMAP の受信箱・回答例)を外部に接続せずに' \
       '作って体験を開始する(rake "toybaco:e2e_trial[e2e-consent-<run>]")'
  task :e2e_trial, %i[prefix] => :environment do |_t, args|
    puts Toybaco::Ops::E2eGrowth.trial(args)
  end

  desc 'staging 専用: 体験を開始した E2E の店舗(ちょうど 1 件)を Standard にし、体験の bot を外して、おまかせ自動返信を全自動で開始する' \
       '(rake "toybaco:e2e_managed_auto[e2e-consent-<run>]")'
  task :e2e_managed_auto, %i[prefix] => :environment do |_t, args|
    puts Toybaco::Ops::E2eGrowth.managed_auto(args)
  end
end

# staging の E2E(規約同意の記録の経路の確認)のうち、Stripe Checkout を通る 2 経路(無料店舗の有料化 growth_purchase と、LP からの開通
# opening_checkout)用。本番の fulfilment(Growth::PurchaseSession#start! → Growth::PurchaseFulfillment#complete! と、Checkout.start! →
# Growth::BillingReceipt.accept! → Growth::OpeningFulfillment#call)をそのまま通し、Stripe の API だけを in-process の偽 client(FakeStripe)に
# 差し替える。Toybaco::Checkout::Client は生成せず、Net::HTTP も開かない(one-shot の container には本物の TOYBACO_STRIPE_KEY がある)。偽の
# Price・Session・購読・請求書は本番の照合を全て通る形にし、金額と商品の名前・説明は PlanCatalog から取る。合成 id は run ごとの prefix の
# - を x に写した英数字に経路の接尾辞(growth は g、opening は o)を付けて作る(Session・購読の unique index と、開通済みの受付の再利用に当たらないよう
# run をまたいで使い回さない)。2 本とも引数は E2E の店舗名の prefix だけで、対象の店舗は E2eGrowth と同じ条件(一致する店舗が E2E の店舗名の
# 厳格な形でちょうど 1 件・有効、契約者が E2E の利用者で確認済みの管理者)。環境の判定と prefix の形は E2eConsent と同じ(staging 以外は引数を
# 読む前に abort。ops-rake workflow も e2e_ で始まるタスクを staging 以外で拒否する二重の fail-closed)。外側の transaction は開かない
# (BillingReceipt と OpeningFulfillment が transaction の中を拒む)。出力は TOYBACO_E2E_GROWTH_PURCHASE / TOYBACO_E2E_OPENING の 1 行(prefix・
# result・店舗の id・reason)だけで、メールアドレス・Session・購読・顧客の id・鍵は出さない。reason は固定の語で、本番の例外の文は出さない。
# 進めないとき(refused)は同じ形の 1 行で abort する(非 0 で終わり、監査行は failed)。同じ prefix の 2 回目は何も書かずに skipped
# (already_done)で正常に終わる。監査行(started / ok|failed)は上の RakeAudit が書く。rake は Rails の初期化前にこのファイルを読むため、
# モデルとサービスは実行時に参照する。ただし GrowthLive の 2 本(e2e_growth_purchase_live / e2e_growth_cancel)と、課金の記録の孤児の
# 後片付け(e2e_purge_billing。下の Orphans の説明)は、偽 client を使わずに Stripe test mode を実際に呼ぶ(下の GrowthLive の説明)。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    module E2eBilling
      GROWTH = 'GROWTH_PURCHASE'
      OPENING = 'OPENING'
      PLAN = 'standard'
      CYCLE = 'month'
      MODE = 'test'
      NONE = '-'

      module_function

      def staging!(task)
        E2eConsent.staging!(task)
      end

      # 本番の Checkout と fulfilment。rake では controller(画面)と webhook が読まれないため、ここで読む(読み済みなら何もしない)。
      def require_billing!
        require Rails.root.join('lib/toybaco/checkout').to_s
        %w[purchase_session purchase_fulfillment billing_mode_client billing_receipt billing_snapshot billing_execution].each do |name|
          require Rails.root.join("lib/toybaco/growth/#{name}").to_s
        end
      end

      # 合成 id の材料。prefix の区切りの - を英字 x に写した英数字(run ごとに違う)に、経路の接尾辞を付ける。区切りを消すだけだと
      # e2e-consent-r12-3 と e2e-consent-r1-23 が同じになるため、x を残して run と attempt の数字を混ぜない(run の店舗名は x を含まない)。
      def tag(prefix, suffix)
        "#{prefix.tr('-', 'x').delete('^A-Za-z0-9')}#{suffix}"
      end

      def version
        Toybaco::GrowthTerms::VERSION
      end

      # toybaco:e2e_growth_purchase[prefix]。購入が済んでいれば(toybaco_growth_purchase が complete)何も書かずに skipped。
      def growth_purchase(args)
        staging!('e2e_growth_purchase')
        require_billing!
        prefix = E2eConsent.prefix!(args)
        account, owner = target!(GROWTH, prefix)
        return line(GROWTH, prefix, 'skipped', account.id, 'already_done') if GrowthSeam.done?(account)

        GrowthSeam.purchase!(prefix, account, owner)
        line(GROWTH, prefix, 'purchased', account.id, NONE)
      end

      # toybaco:e2e_growth_purchase_live[prefix]。e2e_growth_purchase と同じ店舗・前提・行で、Stripe test mode の実経路を通す(GrowthLive)。
      # 購入が済んでいれば、実経路の完了と Stripe の照合が通るときだけ skipped(GrowthLive::Completion)。
      def growth_purchase_live(args)
        staging!('e2e_growth_purchase_live')
        require_billing!
        prefix = E2eConsent.prefix!(args)
        account, owner = target!(GROWTH, prefix)
        return line(GROWTH, prefix, 'skipped', account.id, 'already_done') if GrowthLive::Completion.done!(prefix, account, owner)

        GrowthLive.purchase!(prefix, account, owner)
        line(GROWTH, prefix, 'purchased', account.id, NONE)
      end

      # toybaco:e2e_growth_cancel[prefix]。実経路で買った購読を解約して顧客を消す(GrowthLive::Cancel。店舗の選び方は Cancel が持つ)。
      def growth_cancel(args)
        staging!('e2e_growth_cancel')
        require_billing!
        GrowthLive::Cancel.call(E2eConsent.prefix!(args))
      end

      # toybaco:e2e_opening_checkout[prefix]。この prefix の Session の開通の受付が account_ready なら何も書かずに skipped(開通の後は
      # prefix に一致する店舗が 2 件になるため、対象の店舗を選ぶ前に確かめる)。
      def opening_checkout(args)
        staging!('e2e_opening_checkout')
        require_billing!
        prefix = E2eConsent.prefix!(args)
        ready = OpeningSeam.ready(prefix)
        return OpeningSeam.skipped(prefix, ready) if ready

        account, owner = target!(OPENING, prefix)
        store = OpeningSeam.open!(prefix, account, owner)
        opening_line(prefix, 'opened', store.id, account.id, NONE)
      end

      # 対象の店舗と契約者。E2eGrowth.target! / owner! と同じ条件と理由のキーで、出力の行の形(prefix を含む)だけが違う。
      def target!(label, prefix)
        stores = E2eConsent.accounts(prefix)
        refuse!(label, prefix, 'name_format') unless stores.all? { |store| store.name.match?(E2eConsent::RUN_NAME_FORMAT) }
        refuse!(label, prefix, stores.empty? ? 'no_account' : 'multiple_accounts') unless stores.size == 1

        [stores.first, owner!(label, prefix, stores.first)]
      end

      def owner!(label, prefix, account)
        refuse!(label, prefix, 'account_inactive', account) unless account.active?
        state = Toybaco::Entitlements.attributes(account)[Toybaco::Growth::FreeRegistration::KEY]
        owner = state.is_a?(Hash) ? User.find_by(id: state['owner_id']) : nil
        refuse!(label, prefix, 'owner_missing', account) unless owner
        administrator = account.account_users.exists?(user_id: owner.id, role: :administrator)
        refuse!(label, prefix, 'owner_not_e2e', account) unless E2eConsent.e2e_user?(owner) && administrator
        refuse!(label, prefix, 'owner_unconfirmed', account) unless owner.confirmed?
        owner
      end

      # 販売中の Standard(月払い)の条件(PlanCatalog)。無ければ catalog_unavailable で断る。
      def terms!(label, prefix, account)
        Toybaco::PlanCatalog.default.sale(PLAN, CYCLE, version: version)
      rescue Toybaco::PlanCatalog::Invalid
        refuse!(label, prefix, 'catalog_unavailable', account)
      end

      def standard?(contract)
        contract.is_a?(Hash) && contract.values_at('plan_id', 'plan_version', 'cycle') == [PLAN, version, CYCLE]
      end

      # route の同意の記録(店舗を読み直す)。
      def records(account, route)
        Toybaco::LegalTerms.records(account.reload).select { |record| record.is_a?(Hash) && record['route'] == route }
      end

      # route の同意の記録がちょうど 1 件で、この run の Session・契約者・Stripe の同意欄の結果(accepted)を持つ。
      def consented?(account, route, owner, session_id)
        records(account, route).map { |record| record.values_at('session_id', 'user_id', 'stripe_consent') } == [[session_id, owner.id, 'accepted']]
      end

      def line(label, prefix, result, account_id, reason)
        "TOYBACO_E2E_#{label} prefix=#{prefix} result=#{result} account=#{account_id || NONE} reason=#{reason}"
      end

      # 開通の行。account は作った店舗 B、source_account は店舗 A。
      def opening_line(prefix, result, account_id, source_id, reason)
        "TOYBACO_E2E_#{OPENING} prefix=#{prefix} result=#{result} account=#{account_id || NONE} source_account=#{source_id || NONE} reason=#{reason}"
      end

      # 進めないときの 1 行で abort する。account は対象の店舗 A(開通では source_account)、store は開通で作った店舗 B(作っていれば)。
      def refuse!(label, prefix, reason, account = nil, store: nil)
        abort opening_line(prefix, 'refused', store&.id, account&.id, reason) if label == OPENING

        abort line(label, prefix, 'refused', account&.id, reason)
      end

      # 体験の後・おまかせ自動返信の前の店舗 A を、契約者として Standard(月払い)で有料化する。購入の開始(PurchaseSession#start!)は画面と
      # 同じく購入の記録と Checkout Session を作り、偽の支払いの後に PurchaseFulfillment#complete! を BillingModeClient 越しに呼ぶ
      # (rake toybaco:complete_growth_checkout と同じ直接の経路で、BillingEvent は作らない)。本番の購入の条件(PurchaseIntent#authorize! と
      # PurchaseFulfillment の無料店舗の検査)は先に確かめ、欠ければ何も書かずに断る。購入の後に結果(契約・購読・顧客・AI の枠・体験・
      # 同意の記録)を読み直し、合わなければ payment_mismatch で止める(書いた分は e2e_purge_accounts が店舗ごと消す)。
      module GrowthSeam
        SUFFIX = 'g'

        module_function

        def done?(account)
          Toybaco::Growth::PurchaseIntent.saved(account)&.fetch('state', nil) == 'complete'
        end

        def purchase!(prefix, account, owner)
          terms = ready!(prefix, account, owner)
          stripe = FakeStripe.new(E2eBilling.tag(prefix, SUFFIX), terms)
          start!(prefix, account, owner, stripe)
          stripe.pay!
          complete!(prefix, account, stripe)
          verify!(prefix, account, owner, stripe)
        end

        # 環境と販売の条件、店舗の条件(本番の購入の条件の先回り)、前の実行の購入の記録(complete でないもの。偽 client は run の中だけの
        # ものなので再開しない)、体験(完了していないもの。購入で upgraded になることを確かめる)。販売中の条件を返す。
        def ready!(prefix, account, owner)
          refuse!(prefix, account, 'environment') unless ENV.fetch('TOYBACO_STRIPE_MODE', nil) == MODE
          terms = E2eBilling.terms!(GROWTH, prefix, account)
          store!(prefix, account)
          refuse!(prefix, account, 'not_billing_owner') unless Toybaco::BillingAccess.permissions(account, owner)[:can_manage_billing]
          refuse!(prefix, account, 'purchase_pending') if Toybaco::Growth::PurchaseIntent.saved(account)
          refuse!(prefix, account, 'trial_missing') unless Toybaco::GrowthTrial.exists?(account_id: account.id, completed_at: nil)
          terms
        end

        # 店舗の購入(子店舗の購入の記録)が無く、更新の切り替えの途中でなく、新料金版の無料プランで購読が無い。
        def store!(prefix, account)
          attrs = Toybaco::Entitlements.attributes(account)
          contract = Toybaco::Entitlements.contract_for(account)
          refuse!(prefix, account, 'store_purchase_present') if attrs.key?(Toybaco::StoreFulfillment::PURCHASE)
          refuse!(prefix, account, 'renewal_pending') if Toybaco::Growth::RenewalTransition.pending?(account)
          free = contract&.dig('plan_id') == 'free' && contract.dig('entitlements', 'ai_meter') == Toybaco::GrowthTerms::METER
          refuse!(prefix, account, 'not_free_store') unless free && attrs['toybaco_subscription_id'].blank?
        end

        # 画面の購入の開始と同じく、購入の記録と Checkout Session(開いた状態)を作る。
        def start!(prefix, account, owner, stripe)
          selection = { 'plan_id' => PLAN, 'cycle' => CYCLE, 'plan_version' => E2eBilling.version }
          state = Toybaco::Growth::PurchaseSession.new(account, owner, client: stripe).start!(selection)
          refuse!(prefix, account, 'purchase_unavailable') unless state['state'] == 'open' && stripe.session_id
        rescue Toybaco::Growth::PurchaseIntent::Unavailable, Toybaco::Checkout::Error, Toybaco::PlanCatalog::Invalid
          refuse!(prefix, account, 'purchase_unavailable')
        end

        def complete!(prefix, account, stripe)
          client = Toybaco::Growth::BillingModeClient.new(stripe, MODE)
          result = Toybaco::Growth::PurchaseFulfillment.new(client: client).complete!(stripe.session_id)
          refuse!(prefix, account, 'payment_mismatch') unless result == 'complete'
        rescue Toybaco::Growth::PurchaseIntent::Unavailable, Toybaco::Growth::PaymentSignature::Invalid, Toybaco::SubscriptionSync::Unresolved
          refuse!(prefix, account, 'payment_mismatch')
        end

        # 契約が Standard、購読と顧客が合成値、有料期間の AI の枠が発行され無料の枠が終わり、体験が upgraded で完了し、route growth_purchase の
        # 同意の記録が 1 件(この run の Session・契約者・accepted)。
        def verify!(prefix, account, owner, stripe)
          attrs = Toybaco::Entitlements.attributes(account.reload)
          contract = Toybaco::Entitlements.contract_for(account)
          billed = attrs.values_at('toybaco_subscription_id', 'toybaco_stripe_customer_id') == [stripe.subscription_id, stripe.customer_id]
          upgraded = Toybaco::GrowthTrial.where(account_id: account.id).pluck(:completion_reason) == ['upgraded']
          paid = E2eBilling.standard?(contract) && billed && granted?(account, contract, stripe)
          return if paid && upgraded && E2eBilling.consented?(account, 'growth_purchase', owner, stripe.session_id)

          refuse!(prefix, account, 'payment_mismatch')
        end

        # 有料期間の枠(paid:<購読>:<期間の始まり>:base、Standard の月の回数)が 1 件発行され、無料の枠(free:)が残っていない。
        def granted?(account, contract, stripe)
          grants = Toybaco::GrowthAiGrant.where(account_id: account.id, source: 'included')
          base = "paid:#{Toybaco::GrowthAiGrant.sanitize_sql_like(stripe.subscription_id)}:%:base"
          free = grants.where(revoked_at: nil).where('left(source_key, 5) = ?', 'free:')
          grants.where('source_key LIKE ?', base).pluck(:units) == [contract.dig('entitlements', 'limits', 'ai_generations')] && !free.exists?
        end

        def refuse!(prefix, account, reason)
          E2eBilling.refuse!(GROWTH, prefix, reason, account)
        end
      end

      # 店舗 A の契約者のメール(staging の名簿にある E2E の固定アドレス。出力しない)で LP の開通を通し、店舗 A と同じ名前の店舗 B を作る
      # (Chatwoot の店舗名は unique でない。prefix と E2E の店舗名の形に合うので e2e_purge_accounts が A と一緒に消せる)。Checkout.start! は
      # LP と同じく顧客と Checkout Session を作り、偽の支払い(購入者のメール・会社名 = 店舗 A の名前・業種 other)の後に、BillingSnapshot が
      # opening_checkout に分類する event を BillingReceipt.accept! で受け付け、間を置かずに同じ process で worker(BillingEventJob)と同じ
      # BillingExecution を偽 client で呼ぶ。BillingExecution は event を claim(processing と lease)してから OpeningFulfillment で店舗 B を作り、
      # event を completed の終端状態にする。claim の後と終端状態では、毎分の sweep(BillingReceipt.sweep → BillingEventJob)の worker は
      # event を取らず、本物の client(Toybaco::Checkout::Client)を作らない。残る窓は accept! の commit から claim までの数 ms で、その間に
      # sweep が event を queued にして worker が先に claim したときだけ、worker が本物の client で合成 Session を読みに行く(Stripe は 404 を
      # 返し、event は pending に戻る)。その場合 seam の claim は取れず、request_attention で止まる。店舗 B は OpeningFulfillment が
      # User.from_email で契約者を再利用して作る。受け付けた後に店舗 B を作り終えなければ(断り・例外)、止める前にこの run の開通の受付の
      # 記録を消す(sweep が本物の client で再試行する pending・attention の行を残さない)。開通の後の運営宛てメール
      # (OpeningOperations.opened!)と、毎分の初期設定(OpeningOnboarding.sweep。転送用受信箱とログイン案内)は本番と同じく動く。
      module OpeningSeam
        SUFFIX = 'o'
        INDUSTRY = 'other'

        module_function

        def session_id(prefix)
          "cs_test_#{E2eBilling.tag(prefix, SUFFIX)}"
        end

        def event_id(prefix)
          "evt_#{E2eBilling.tag(prefix, SUFFIX)}"
        end

        def ready(prefix)
          Toybaco::OpeningRequest.find_by(mode: MODE, session_id: session_id(prefix), state: 'account_ready')
        end

        # 2 回目の行。店舗 B は開通済みの受付の店舗、店舗 A は prefix に一致するほかの店舗(ちょうど 1 件のときだけ出す)。
        def skipped(prefix, request)
          sources = E2eConsent.accounts(prefix).reject { |store| store.id == request.account_id }
          E2eBilling.opening_line(prefix, 'skipped', request.account_id, sources.one? ? sources.first.id : nil, 'already_done')
        end

        def open!(prefix, account, owner)
          terms = ready!(prefix, account, owner)
          stripe = FakeStripe.new(E2eBilling.tag(prefix, SUFFIX), terms)
          start!(prefix, account, stripe)
          stripe.pay!(email: owner.email.to_s.downcase, company: account.name, industry: INDUSTRY)
          settle!(prefix, account, owner, stripe)
        end

        # 受け付けてから確かめ終えるまで。店舗 B を作り終えなければ(断りの abort と例外)、この run の開通の受付の記録を消してから止める。
        def settle!(prefix, account, owner, stripe)
          row = accept!(prefix, account, stripe)
          fulfill!(row, stripe)
          store = verify!(prefix, account, owner, stripe, row)
          opened = true
          store
        ensure
          discard!(prefix) unless opened
        end

        # この run の合成 id(Session・event)の開通の受付と、それに結んだ event・案内を消す(FK の順に 1 つの transaction で)。前の run の
        # 残りは ready! が断るので、ここで消す行はこの run が作ったものだけ。
        def discard!(prefix)
          Toybaco::OpeningRequest.transaction do
            requests = Toybaco::OpeningRequest.where(mode: MODE, session_id: session_id(prefix))
            Toybaco::OpeningNotice.where(opening_request_id: requests.select(:id)).delete_all
            events = Toybaco::BillingEvent.where(mode: MODE)
            events.where(opening_request_id: requests.select(:id)).or(events.where(event_id: event_id(prefix))).delete_all
            requests.delete_all
          end
        end

        # 環境、staging の開通の照合(OpeningTerms)が通す名簿のメール、前の run の残り(同じ合成 id の受付・event)、販売の条件。
        # 販売中の条件を返す。
        def ready!(prefix, account, owner)
          refuse!(prefix, account, 'environment') unless ENV.fetch('TOYBACO_STRIPE_MODE', nil) == MODE
          refuse!(prefix, account, 'fixture_email') unless roster.include?(owner.email.to_s.strip.downcase)
          leftover = Toybaco::OpeningRequest.exists?(mode: MODE, session_id: session_id(prefix)) ||
                     Toybaco::BillingEvent.exists?(mode: MODE, event_id: event_id(prefix))
          refuse!(prefix, account, 'request_attention') if leftover
          E2eBilling.terms!(OPENING, prefix, account)
        end

        # OpeningTerms の名簿の読み方と同じ(カンマ区切り、前後の空白を除き小文字にそろえる)。
        def roster
          ENV.fetch('TOYBACO_STAGING_FIXTURE_EMAILS', '').split(',').map { |value| value.strip.downcase }
        end

        # LP の申し込みと同じ(checkout_controller の Checkout.start! に、確認画面の同意の記録を渡す)。
        def start!(prefix, account, stripe)
          Toybaco::Checkout.start!(plan: PLAN, cycle: CYCLE, version: E2eBilling.version, consent: Toybaco::LegalTerms.consent, client: stripe,
                                   environment: ENV)
        rescue Toybaco::Checkout::Error, Toybaco::PlanCatalog::Invalid
          refuse!(prefix, account, 'catalog_unavailable')
        end

        # webhook の controller と同じく event を分類して受け付ける(署名の検証は Stripe の event でないため通らない。job は積まない)。
        def accept!(prefix, account, stripe)
          attributes = Toybaco::Growth::BillingSnapshot.new(stripe.completed_event(event_id(prefix))).read
          refuse!(prefix, account, 'payment_mismatch') unless attributes.is_a?(Hash) && attributes[:action] == 'opening_checkout'
          Toybaco::Growth::BillingReceipt.accept!(attributes)
        rescue Toybaco::Growth::PaymentSignature::Invalid, Toybaco::Growth::BillingReceipt::Conflict
          refuse!(prefix, account, 'payment_mismatch')
        end

        # worker(BillingEventJob)と同じ BillingExecution で、event を claim して処理する(client だけ偽物)。claim が取れなければ(worker が
        # 先に取った)何もせずに戻る。断りと例外は BillingExecution が event の状態(pending / attention)に写すので、結果は受付と event の
        # 状態を読み直して判定する(verify!)。
        def fulfill!(row, stripe)
          Toybaco::Growth::BillingExecution.new(row, client: stripe).call
        end

        # 受付が account_ready で event が completed(終端状態)、店舗 B が店舗 A と同じ名前の別の店舗、B の管理者が A の契約者(同じ User)、
        # route opening_checkout の同意の記録が B に 1 件(この run の Session・契約者・accepted)で、A には無い。店舗 B を返す。
        def verify!(prefix, account, owner, stripe, row)
          request = Toybaco::OpeningRequest.find_by(mode: MODE, session_id: stripe.session_id)
          refuse!(prefix, account, 'request_attention') unless request&.state == 'account_ready' && row.reload.state == 'completed'
          store = Account.find_by(id: request.account_id)
          refuse!(prefix, account, 'payment_mismatch', store) unless store && opened?(store, account, owner, request.owner_id, stripe)
          store
        end

        def opened?(store, account, owner, owner_id, stripe)
          return false unless store.id != account.id && store.name == account.name && owner_id == owner.id

          administrator = store.account_users.exists?(user_id: owner.id, role: :administrator)
          administrator && E2eBilling.consented?(store, 'opening_checkout', owner, stripe.session_id) &&
            E2eBilling.records(account, 'opening_checkout').empty?
        end

        def refuse!(prefix, account, reason, store = nil)
          E2eBilling.refuse!(OPENING, prefix, reason, account, store: store)
        end
      end

      # Stripe の API の偽物(in-process、Ruby だけで、どこにも接続しない)。本番の client(Toybaco::Checkout::Client)と同じメソッド名・
      # 引数で、1 つの run の Session と購読をメモリに持つ。合成 id は tag(E2eBilling.tag。prefix と経路の接尾辞)から作り、Price は販売中の
      # 条件(terms)の金額・商品の名前と説明を持つ。retrieve は保存した Hash の複製を返す(何度読んでも同じ Hash。開通の照合は 2 回の
      # 読み取りの一致を求める)。開通は Session を idempotency_key なしで作る(Checkout.start!)ので、キーワード引数は任意にする。
      class FakeStripe
        attr_reader :session_id

        def initialize(tag, terms)
          @tag = tag
          @terms = terms
          @sessions = {}
          @subscriptions = {}
          @subscription_metadata = {}
        end

        def customer_id
          "cus_#{@tag}"
        end

        def subscription_id
          "sub_#{@tag}"
        end

        def price_id
          "price_#{@tag}"
        end

        # 販売中の条件の test mode の lookup_key だけに Price を返す(ほかの key は見つからない)。
        def find_price_by_lookup_key(key)
          price if key == @terms.dig('cycles', CYCLE, 'stripe', MODE, 'lookup_key')
        end

        # Price の環境変数の上書きがあるときの経路(Checkout::Resolver)。上書きの id に関わらず同じ合成の Price を返す。
        def retrieve_price(_id)
          price
        end

        def create_customer(_params)
          { 'id' => customer_id, 'object' => 'customer', 'livemode' => false }
        end

        # 1 つの run の Session は 1 つだけ(作り直しの呼び出しには同じ Session を返す。idempotency_key と同じ働き)。
        def create_checkout_session(params, **_options)
          unless @session_id
            @session_id = "cs_test_#{@tag}"
            @sessions[@session_id] = open_session(@session_id, params)
            @subscription_metadata = form(params, 'subscription_data[metadata][')
          end
          retrieve_checkout_session(@session_id)
        end

        def retrieve_checkout_session(id)
          @sessions.fetch(id) { raise Toybaco::Checkout::Error, 'stripe 404' }.deep_dup
        end

        def retrieve_subscription(id)
          @subscriptions.fetch(id) { raise Toybaco::Checkout::Error, 'stripe 404' }.deep_dup
        end

        def expire_checkout_session(id, **_options)
          session = @sessions.fetch(id) { raise Toybaco::Checkout::Error, 'stripe 404' }
          session['status'] = 'expired' if session['status'] == 'open'
          retrieve_checkout_session(id)
        end

        def list_checkout_sessions(**_options)
          { 'data' => @sessions.values.map(&:deep_dup), 'has_more' => false }
        end

        # 偽の支払い: Session を完了・支払い済みにし、購読(有効・今の期間・支払い済みの初回の請求書)を付ける。同意欄が必須の Session には
        # Stripe と同じく同意欄の結果(accepted)を入れる。開通は購入者のメールと、会社名・業種の入力欄の値も入れる。
        def pay!(email: nil, company: nil, industry: nil)
          session = @sessions.fetch(@session_id)
          @subscriptions[subscription_id] = subscription(Time.now.to_i - 60)
          accepted = session.dig('consent_collection', 'terms_of_service') == 'required'
          session.merge!('status' => 'complete', 'payment_status' => 'paid', 'customer' => customer_id, 'subscription' => subscription_id,
                         'currency' => 'jpy', 'amount_subtotal' => amount, 'total_details' => { 'amount_discount' => 0, 'amount_shipping' => 0 },
                         'consent' => accepted ? { 'terms_of_service' => 'accepted' } : nil)
          session.merge!(contact(email, company, industry)) if email
          session_id
        end

        # 開通の受付に渡す checkout.session.completed の event(過去の作成時刻・test mode・data.object は完了した Session)。
        def completed_event(id)
          { 'id' => id, 'object' => 'event', 'type' => 'checkout.session.completed', 'livemode' => false, 'created' => Time.now.to_i - 1,
            'data' => { 'object' => retrieve_checkout_session(@session_id) } }
        end

        private

        def open_session(id, params)
          { 'id' => id, 'object' => 'checkout.session', 'mode' => 'subscription', 'livemode' => false, 'status' => 'open',
            'payment_status' => 'unpaid', 'client_reference_id' => params['client_reference_id'], 'customer' => params['customer'],
            'metadata' => form(params, 'metadata['), 'created' => Time.now.to_i, 'expires_at' => params['expires_at']&.to_i,
            'consent_collection' => { 'terms_of_service' => params['consent_collection[terms_of_service]'] || 'none' },
            'url' => "https://checkout.stripe.com/c/pay/#{id}" }
        end

        # form の key(<prefix><name>])の値を name ごとに取り出す(metadata[...] / subscription_data[metadata][...])。
        def form(params, prefix)
          params.each_with_object({}) do |(key, value), found|
            found[key.delete_prefix(prefix).delete_suffix(']')] = value if key.start_with?(prefix) && key.end_with?(']')
          end
        end

        def contact(email, company, industry)
          { 'customer_details' => { 'email' => email },
            'custom_fields' => [{ 'key' => 'company', 'type' => 'text', 'text' => { 'value' => company } },
                                { 'key' => 'industry', 'type' => 'dropdown', 'dropdown' => { 'value' => industry } }] }
        end

        def amount
          @terms.dig('cycles', CYCLE, 'amount')
        end

        def price
          { 'id' => price_id, 'object' => 'price', 'active' => true, 'currency' => 'jpy', 'unit_amount' => amount, 'livemode' => false,
            'tax_behavior' => 'exclusive', 'billing_scheme' => 'per_unit', 'transform_quantity' => nil,
            'recurring' => { 'interval' => CYCLE, 'interval_count' => 1, 'usage_type' => 'licensed' },
            'metadata' => { 'toybaco_plan' => @terms.fetch('plan_id'), 'toybaco_plan_version' => @terms.fetch('plan_version') },
            'product' => { 'id' => "prod_#{@tag}", 'active' => true, 'name' => @terms.fetch('product_name'),
                           'description' => @terms.fetch('description') } }
        end

        # 有効な購読。今の期間は started(今より前)から 1 か月で、請求の起点と初回の請求書の支払いの時刻も started。
        def subscription(started)
          ends = Time.at(started).utc.advance(months: 1).to_i
          item = { 'id' => "si_#{@tag}", 'price' => price, 'quantity' => 1, 'current_period_start' => started, 'current_period_end' => ends }
          { 'id' => subscription_id, 'object' => 'subscription', 'status' => 'active', 'livemode' => false, 'customer' => customer_id,
            'metadata' => @subscription_metadata, 'billing_cycle_anchor' => started, 'cancel_at_period_end' => false, 'pause_collection' => nil,
            'items' => { 'object' => 'list', 'has_more' => false, 'data' => [item] }, 'latest_invoice' => invoice(started, ends) }
        end

        def invoice(started, ends)
          line = { 'quantity' => 1, 'amount' => amount, 'period' => { 'start' => started, 'end' => ends },
                   'parent' => { 'subscription_item_details' => { 'subscription_item' => "si_#{@tag}" } },
                   'pricing' => { 'price_details' => { 'price' => price_id } } }
          { 'id' => "in_#{@tag}", 'object' => 'invoice', 'status' => 'paid', 'currency' => 'jpy', 'amount_remaining' => 0,
            'billing_reason' => 'subscription_create', 'parent' => { 'subscription_details' => { 'subscription' => subscription_id } },
            'status_transitions' => { 'paid_at' => started }, 'lines' => { 'object' => 'list', 'has_more' => false, 'data' => [line] } }
        end
      end

      # 無料店舗の有料化(route growth_purchase)を Stripe test mode の実経路で通す 2 本(e2e_growth_purchase_live / e2e_growth_cancel)。
      # 対象の店舗・前提・出力の行は GrowthSeam と同じで、Stripe だけが本物(鍵は container の env の TOYBACO_STRIPE_KEY。sk_test / rk_test に限る)。
      # 購入は本番の PurchaseSession#start! が実 client で購入の記録と Checkout Session を作り、決済は Checkout の決済画面が使う payment page の
      # API(9/26 の購入通し確認と同じ。GET → tok_visa の PaymentMethod → confirm。カード番号は扱わない)で済ませる。fulfillment は rake から
      # 呼ばず、実 webhook(Stripe → Lambda → Rails → BillingReceipt → BillingEventJob → PurchaseFulfillment)の結果を待ってから、契約・購読・
      # 顧客・AI の枠・体験・同意の記録を Stripe の Session と照合する。決済を確定した後(確定の応答が失敗でも Stripe の Session が完了して
      # いれば確定済み)は、待っても終わらない・合わない・途中の例外のどれでも、止める前に購読を解約する。後片付けは購読を解約して顧客を
      # 消し、解約の event が Rails に届いて終端になるのを待ってから、この run の id の完了した event を消す(途中で止まっても再実行で
      # 残りを続ける)。Session・購読・顧客・PaymentMethod の id・メールアドレス・金額・鍵は出力・abort の文・例外のどこにも出さない
      # (例外は理由のキーに写し、元の例外を連鎖させない)。
      module GrowthLive
        KEY_FORMAT = /\A(?:sk|rk)_test_/
        SESSION_FORMAT = /\Acs_test_[A-Za-z0-9]+\z/
        SUBSCRIPTION_FORMAT = /\Asub_[A-Za-z0-9]+\z/
        CUSTOMER_FORMAT = /\Acus_[A-Za-z0-9]+\z/
        PAYMENT_METHOD_FORMAT = /\Apm_[A-Za-z0-9]+\z/
        INTERVAL = 5
        PURCHASE_WAIT = 180

        module_function

        def key
          ENV.fetch('TOYBACO_STRIPE_KEY', '').to_s
        end

        # GrowthSeam と同じ前提(同じ理由のキー)に加えて、鍵が test mode で、webhook が Rails に届く構成(ingress)であることを確かめる。
        # 理由のキーに写していない例外(DB の失敗など。SystemExit と signal は StandardError でないので捕まえない)は、例外の文を出さずに
        # purchase_error で止める(決済の確定の後の例外は settle! が解約してから settle_error に写す)。
        def purchase!(prefix, account, owner)
          GrowthSeam.ready!(prefix, account, owner)
          refuse!(prefix, account, 'key_not_test') unless key.match?(KEY_FORMAT)
          refuse!(prefix, account, 'ingress_off') unless ENV.fetch('TOYBACO_BILLING_INGRESS_ENABLED', nil) == 'true'
          client, session_id = start!(prefix, account, owner)
          Payment.pay!(prefix, account, owner, client, session_id)
          settle!(prefix, account, owner, client, session_id)
        rescue StandardError
          refuse!(prefix, account, 'purchase_error')
        end

        # 画面の購入の開始と同じく、購入の記録と Checkout Session(開いた状態)を実 client で作る。Session の id は購入の記録から読む。
        def start!(prefix, account, owner)
          client = Toybaco::Checkout::Client.new(key)
          selection = { 'plan_id' => PLAN, 'cycle' => CYCLE, 'plan_version' => E2eBilling.version }
          state = Toybaco::Growth::PurchaseSession.new(account, owner, client: client).start!(selection)
          session_id = Toybaco::Growth::PurchaseIntent.saved(account.reload)&.fetch('session_id', nil)
          refuse!(prefix, account, 'purchase_unavailable') unless state['state'] == 'open' && session_id.to_s.match?(SESSION_FORMAT)
          [client, session_id]
        rescue Toybaco::Growth::PurchaseIntent::Unavailable, Toybaco::Checkout::Error, Toybaco::PlanCatalog::Invalid
          refuse!(prefix, account, 'purchase_unavailable')
        end

        # 決済の確定の後の待機と照合。通らなければ(途中の例外を含む)購読を解約してから理由の 1 行で止める。
        def settle!(prefix, account, owner, client, session_id)
          reason = unsettled(account, owner, client, session_id)
          abandon!(prefix, account, client, session_id, reason) if reason
        end

        # webhook の結果(購入の記録が complete で、この Session の growth_checkout の event が completed)を待ち、Stripe と照合する。通れば
        # nil、通らなければ理由のキー(待っても終わらない webhook_timeout、合わない payment_mismatch、途中の例外 settle_error。SystemExit と
        # signal は StandardError でないので捕まえない)。例外の文は持ち出さない。
        def unsettled(account, owner, client, session_id)
          return 'webhook_timeout' unless wait_until(PURCHASE_WAIT) { purchased?(account, session_id) }

          'payment_mismatch' unless purchase_verified?(account, owner, session_id, client.retrieve_checkout_session(session_id))
        rescue Toybaco::Checkout::Error
          'payment_mismatch'
        rescue StandardError
          'settle_error'
        end

        def purchased?(account, session_id)
          Toybaco::Growth::PurchaseIntent.saved(account.reload)&.fetch('state', nil) == 'complete' &&
            Toybaco::BillingEvent.where(action: 'growth_checkout', reference_id: session_id, mode: MODE).pick(:state) == 'completed'
        end

        # 条件が満たされるまで INTERVAL 秒おきに確かめる(待つのは最長 seconds 秒)。満たされたかを返す。
        def wait_until(seconds)
          (seconds / INTERVAL).times do
            return true if yield

            pause(INTERVAL)
          end
          yield
        end

        def pause(seconds)
          sleep(seconds)
        end

        # Stripe の Session(test mode)の購読・顧客が店舗の契約の購読・顧客と同じで、契約が Standard、有料期間の AI の枠が発行され無料の枠が
        # 終わり、体験が upgraded で完了し、route growth_purchase の同意の記録が 1 件(この run の Session・契約者・accepted)。
        def purchase_verified?(account, owner, session_id, session)
          contract = Toybaco::Entitlements.contract_for(account.reload)
          upgraded = Toybaco::GrowthTrial.where(account_id: account.id).pluck(:completion_reason) == ['upgraded']
          billed?(account, session) && upgraded && E2eBilling.standard?(contract) && granted?(account, contract, session['subscription']) &&
            E2eBilling.consented?(account, 'growth_purchase', owner, session_id)
        end

        # Session が test mode で完了・支払い済み、購読・顧客の id の形が合い、店舗の契約の購読・顧客と同じ。
        def billed?(account, session)
          ids = session.values_at('subscription', 'customer')
          session.values_at('livemode', 'status', 'payment_status') == [false, 'complete', 'paid'] &&
            ids.first.to_s.match?(SUBSCRIPTION_FORMAT) && ids.last.to_s.match?(CUSTOMER_FORMAT) &&
            Toybaco::Entitlements.attributes(account).values_at('toybaco_subscription_id', 'toybaco_stripe_customer_id') == ids
        end

        # 有料期間の枠(paid:<購読>:<期間の始まり>:base、Standard の月の回数)が 1 件発行され、無料の枠(free:)が残っていない(GrowthSeam と同じ)。
        def granted?(account, contract, subscription_id)
          grants = Toybaco::GrowthAiGrant.where(account_id: account.id, source: 'included')
          base = "paid:#{Toybaco::GrowthAiGrant.sanitize_sql_like(subscription_id)}:%:base"
          free = grants.where(revoked_at: nil).where('left(source_key, 5) = ?', 'free:')
          grants.where('source_key LIKE ?', base).pluck(:units) == [contract.dig('entitlements', 'limits', 'ai_generations')] && !free.exists?
        end

        # 止める前に、Session に購読があれば解約する(請求しない・日割りしない)。解約に失敗しても理由は変えない。
        def abandon!(prefix, account, client, session_id, reason)
          cancel_quietly(client, session_id)
          refuse!(prefix, account, reason)
        end

        def cancel_quietly(client, session_id)
          subscription = client.retrieve_checkout_session(session_id)['subscription']
          client.cancel_unpaid_subscription(subscription) if subscription.to_s.match?(SUBSCRIPTION_FORMAT)
        rescue StandardError
          nil
        end

        def refuse!(prefix, account, reason)
          stop!(E2eBilling.line(GROWTH, prefix, 'refused', account&.id, reason))
        end

        # 進めないときの 1 行を標準エラーに出して終了コード 1 で終わる(abort と同じ出力と終了コード)。rescue の中から呼ばれても、SystemExit の
        # cause に元の例外(本物の client の例外は応答の断片を持ちうる)を残さない。
        def stop!(line)
          warn(line)
          raise SystemExit.new(1, line), cause: nil
        end

        # e2e_growth_purchase_live の 2 回目の判定。購入の記録が complete でなければ偽(購入へ進む)。complete なら、実経路の完了(購入の記録の
        # Session の growth_checkout の event が completed)が無ければ、event を作らない偽 client の e2e_growth_purchase で済ませた店舗なので
        # seam_purchase_present で断る(fail-closed)。あれば実 client で Session と購読を読み直し、購読が有効(active / trialing)で照合
        # (purchase_verified?)が通るときだけ真(skipped)。購読が有効でなければ subscription_inactive、照合が合わなければ payment_mismatch で
        # 断る(解約は試みない。合わなかった実行の abandon! か、後段の e2e_growth_cancel が拾う)。理由のキーに写していない例外は purchase!
        # と同じく purchase_error で止める。
        module Completion
          ACTIVE = %w[active trialing].freeze

          module_function

          def done!(prefix, account, owner)
            return false unless GrowthSeam.done?(account)

            session_id = Toybaco::Growth::PurchaseIntent.saved(account)['session_id']
            GrowthLive.refuse!(prefix, account, 'seam_purchase_present') unless live?(session_id)
            GrowthLive.refuse!(prefix, account, 'key_not_test') unless GrowthLive.key.match?(KEY_FORMAT)
            reason = mismatch(account, owner, session_id)
            GrowthLive.refuse!(prefix, account, reason) if reason
            true
          rescue StandardError
            GrowthLive.refuse!(prefix, account, 'purchase_error')
          end

          def live?(session_id)
            session_id.to_s.match?(SESSION_FORMAT) &&
              Toybaco::BillingEvent.exists?(action: 'growth_checkout', reference_id: session_id, mode: MODE, state: 'completed')
          end

          # 通れば nil、通らなければ理由のキー(Stripe を読めないときも payment_mismatch)。
          def mismatch(account, owner, session_id)
            client = Toybaco::Checkout::Client.new(GrowthLive.key)
            session = client.retrieve_checkout_session(session_id)
            return 'subscription_inactive' unless ACTIVE.include?(client.retrieve_subscription(session['subscription'].to_s)['status'])

            'payment_mismatch' unless GrowthLive.purchase_verified?(account, owner, session_id, session)
          rescue Toybaco::Checkout::Error
            'payment_mismatch'
          end
        end

        # payment page で Session を読んで確かめ、tok_visa から PaymentMethod(請求先は契約者のメールと店舗名)を作り、税込の合計で確定する
        # (Checkout の決済画面と同じ API。カード番号は扱わない)。同意欄は accepted で送り、入力欄(growth の Session には無い)は送らない。
        # growth の Session は顧客を結ばず住所が未確定なので、page の合計は税抜(小計と同じ)のことがある。Stripe は確定のときに
        # PaymentMethod の住所(ADDRESS)から税(JCT)を計算した税込の合計と expected_amount を比べるため(違えば 400
        # checkout_amount_mismatch)、expected_amount は page の合計ではなく、製品の表示の税率(display_tax_rate)から計算した税込の合計を送る。
        module Payment
          TOKEN = 'tok_visa'
          # 自動の税の計算(JCT)に要る請求先の住所(9/26 の購入通し確認と同じ固定値)。
          ADDRESS = { 'country' => 'JP', 'postal_code' => '810-0022', 'state' => '福岡県', 'city' => '福岡市中央区', 'line1' => '薬院1-1-1' }.freeze
          # 理由の長さの上限(one-shot の終端行の形: GROWTH_PURCHASE の reason は英小文字・数字・_ の 40 字まで)。
          REASON_LIMIT = 40

          module_function

          def pay!(prefix, account, owner, client, session_id)
            api = ApiHandler.new(GrowthLive.key)
            total = page_total!(prefix, account, api, session_id)
            method = payment_method!(prefix, account, owner, api)
            reason = confirmation(api, session_id,
                                  { 'payment_method' => method, 'expected_amount' => total.to_s, 'consent[terms_of_service]' => 'accepted' })
            unconfirmed!(prefix, account, client, session_id, reason) if reason
          end

          # page が購入の記録と合えば、確定に送る税込の合計(page の合計が税抜でも税込でも同じ値)を返す。
          def page_total!(prefix, account, api, session_id)
            page = api.payment_page(session_id)
            amount = Toybaco::Growth::PurchaseIntent.saved(account)['amount']
            return taxed(amount) if page_matches?(page, amount)

            refuse!(prefix, account, 'payment_page_mismatch')
          rescue ApiHandler::Failure
            refuse!(prefix, account, 'payment_page_unavailable')
          end

          # 税抜の金額に製品の表示の税率(Checkout::Catalog の MONTHLY_AMOUNTS と同じ式)を掛けた税込の合計。
          def taxed(amount)
            (amount * (1 + Toybaco::Checkout::Catalog::DATA.data.fetch('display_tax_rate'))).round
          end

          # test mode・開いた状態・購読・円・同意欄が必須・入力欄なしで、小計が購入の記録の金額(税抜の正の整数)と同じ、合計が整数で、
          # 税抜(住所が未確定)か税込(taxed)のどちらか。それ以外の合計は通さない。
          def page_matches?(page, amount)
            summary = page['total_summary'].is_a?(Hash) ? page['total_summary'] : {}
            consent = page['consent_collection'].is_a?(Hash) ? page['consent_collection'] : {}
            total = summary['total']
            [page.values_at('livemode', 'status', 'mode', 'currency') == [false, 'open', 'subscription', 'jpy'],
             consent['terms_of_service'] == 'required', page['custom_fields'] == [],
             amount.is_a?(Integer) && amount.positive? && summary['subtotal'] == amount &&
               total.is_a?(Integer) && [amount, taxed(amount)].include?(total)].all?
          end

          def payment_method!(prefix, account, owner, api)
            fields = { 'type' => 'card', 'card[token]' => TOKEN, 'billing_details[email]' => owner.email.to_s,
                       'billing_details[name]' => account.name }
            ADDRESS.each { |name, value| fields["billing_details[address][#{name}]"] = value }
            id = api.create_card_payment_method(fields, idempotency_key: "toybaco-e2e-growth-live-#{prefix}-pm")['id']
            return id if id.to_s.match?(PAYMENT_METHOD_FORMAT)

            refuse!(prefix, account, 'payment_method_failed')
          rescue ApiHandler::Failure
            refuse!(prefix, account, 'payment_method_failed')
          end

          # 確定の応答が完了・支払い済みなら nil、そうでなければ理由のキー(HTTP の失敗は status code と Stripe の error の code だけを足す。
          # 本文は出さない)。
          def confirmation(api, session_id, fields)
            result = api.confirm(session_id, fields)
            'confirm_failed' unless result['status'] == 'complete' && result['payment_status'] == 'paid'
          rescue ApiHandler::Failure => e
            failure_reason(e)
          end

          # code が無ければ confirm_failed(status があれば confirm_failed_<status>)、あれば confirm_<status>_<code>(status が無ければ
          # confirm_failed_<code>)。REASON_LIMIT の字数に切り詰める。
          def failure_reason(error)
            reason = error.code ? "confirm_#{error.status || 'failed'}_#{error.code}" : ['confirm_failed', error.status].compact.join('_')
            reason[0, REASON_LIMIT]
          end

          # 確定の応答が完了でなければ、Stripe の Session を読み直し、完了していれば確定済みとして先へ進む(残りは webhook が進める)。完了して
          # いなければ、購読があれば解約してから止める。
          def unconfirmed!(prefix, account, client, session_id, reason)
            GrowthLive.abandon!(prefix, account, client, session_id, reason) unless confirmed?(client, session_id)
          end

          # 確定の応答が完了でなくても(応答の消失・途中の失敗)、Stripe の Session が完了していれば確定済み。読めなければ確定済みとは
          # 見なさない。
          def confirmed?(client, session_id)
            client.retrieve_checkout_session(session_id)['status'] == 'complete'
          rescue StandardError
            false
          end

          def refuse!(prefix, account, reason)
            GrowthLive.refuse!(prefix, account, reason)
          end
        end

        # Stripe の payment page(Checkout の決済画面が使う非公開 API)・PaymentMethod・顧客・購読の一覧・Checkout Session(retrieve と購読の Session の
        # 一覧)の API を Net::HTTP で呼ぶ(staging の growth webhook probe と同じ作法: Bearer、open / read timeout 10 / 30 秒、応答 1 MiB 以下、
        # JSON の object)。payment page は非公開
        # API なので Stripe-Version を付けず、公開 API(PaymentMethod・顧客・購読)には probe と同じ版を付ける。id は形を確かめてから path に
        # 入れる。失敗は全て Failure(HTTP の status code と、非 2xx の応答の Stripe の error の code だけを持つ)に写し、鍵・id・応答の本文・
        # error の message・param・元の例外の文は持たない(cause: nil で元の例外の連鎖も切る)。
        class ApiHandler
          HOST = 'api.stripe.com'
          VERSION = '2024-06-20'
          LIMIT = 1_048_576

          class Failure < StandardError
            # Stripe の error の code(checkout_amount_mismatch など)として持つ形。小文字にしてから確かめ、合わなければ持たない(長さは
            # 理由を作るときに全体で切り詰める)。
            CODE = /\A[a-z0-9_]+\z/

            attr_reader :status, :code

            def initialize(status = nil, code: nil)
              @status = status.to_s.match?(/\A\d{3}\z/) ? status.to_s : nil
              @code = code.is_a?(String) && code.valid_encoding? && code.downcase.match?(CODE) ? code.downcase : nil
              super('stripe request failed')
            end
          end

          def initialize(key)
            @key = key.to_s
          end

          def payment_page(session_id)
            request(:get, "/v1/payment_pages/#{id!(session_id, SESSION_FORMAT)}")
          end

          def create_card_payment_method(fields, idempotency_key:)
            request(:post, '/v1/payment_methods', fields, version: VERSION, idempotency_key: idempotency_key)
          end

          def confirm(session_id, fields)
            request(:post, "/v1/payment_pages/#{id!(session_id, SESSION_FORMAT)}/confirm", fields)
          end

          def retrieve_customer(customer_id)
            request(:get, "/v1/customers/#{id!(customer_id, CUSTOMER_FORMAT)}", version: VERSION)
          end

          # 顧客の購読(解約済みを含む全件。100 件まで)。
          def list_subscriptions(customer_id)
            query = URI.encode_www_form([['customer', id!(customer_id, CUSTOMER_FORMAT)], %w[status all], %w[limit 100]])
            request(:get, "/v1/subscriptions?#{query}", version: VERSION)
          end

          def delete_customer(customer_id)
            request(:delete, "/v1/customers/#{id!(customer_id, CUSTOMER_FORMAT)}", version: VERSION)
          end

          # Checkout Session(e2e_purge_billing の照合。購読と、その既定の PaymentMethod を展開して請求先の名前を読む)。本番の
          # Checkout::Client は変えず、照合はこの helper で読む。
          def checkout_session(session_id)
            query = URI.encode_www_form([['expand[]', 'subscription.default_payment_method']])
            request(:get, "/v1/checkout/sessions/#{id!(session_id, SESSION_FORMAT)}?#{query}", version: VERSION)
          end

          # 購読を作った Checkout Session(1 件まで。e2e_purge_billing の照合。購読と、その既定の PaymentMethod を展開する)。
          def subscription_sessions(subscription_id)
            query = URI.encode_www_form([['subscription', id!(subscription_id, SUBSCRIPTION_FORMAT)], %w[limit 1],
                                         ['expand[]', 'data.subscription.default_payment_method']])
            request(:get, "/v1/checkout/sessions?#{query}", version: VERSION)
          end

          private

          def id!(value, format)
            raise Failure.new, cause: nil unless value.is_a?(String) && value.match?(format)

            value
          end

          def request(method, path, fields = nil, version: nil, idempotency_key: nil)
            require 'net/http'
            uri = URI("https://#{HOST}#{path}")
            message = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }.fetch(method).new(uri)
            message['Authorization'] = "Bearer #{@key}"
            message['Stripe-Version'] = version if version
            message['Idempotency-Key'] = idempotency_key if idempotency_key
            message.set_form_data(fields) if fields
            parse(Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) { |http| http.request(message) })
          rescue Failure
            raise
          rescue StandardError
            raise Failure.new, cause: nil
          end

          def parse(response)
            raise Failure.new(response.code, code: error_code(response)), cause: nil unless response.is_a?(Net::HTTPSuccess)
            raise Failure.new, cause: nil if response.body.to_s.bytesize > LIMIT

            value = JSON.parse(response.body.to_s)
            raise Failure.new, cause: nil unless value.is_a?(Hash)

            value
          end

          # 非 2xx の応答の本文(LIMIT 以下の JSON の object)から error の code だけを読む(形は Failure が確かめる)。本文が大きすぎる・JSON で
          # ない・error が object でなければ nil。
          def error_code(response)
            body = response.body.to_s
            return if body.bytesize > LIMIT

            value = JSON.parse(body)
            value['error']['code'] if value.is_a?(Hash) && value['error'].is_a?(Hash)
          rescue StandardError
            nil
          end
        end

        # toybaco:e2e_growth_cancel の本体。prefix に一致する店舗(開通の後は A と同名の B の 2 件)のうち、購入の記録が complete の店舗か、
        # Session のある未完了(open / payment_pending。決済の確定の後に webhook の結果を待たずに止まった購入)の店舗を選び、解約する購読を
        # 決める(complete なら店舗の契約の購読、未完了なら Stripe の Session が完了していればその購読。完了していなければ何もせずに
        # skipped)。購読がこの run の購入のもの(test mode・metadata の店舗 id)であることを確かめてから解約し(既に解約済みなら解約の
        # 呼び出しだけを省く)、顧客を消し(既に消えていれば省く。消す前に、契約者のメール・この店舗の購入の Session の顧客・Stripe でこの
        # 顧客の購読がこの購読だけ・DB でほかの店舗がこの顧客を持たないことを確かめる)、解約の event(customer.subscription.deleted)が
        # Rails に届いて終端になり、この run の id(Session・購読)の event に処理中(pending・queued・processing)が無くなるまで待ってから、
        # この run の id の終端の event を全て消す(解約の event も残さない)。この購読の同期の依頼(toybaco_subscription_sync_requests)のうち、
        # 店舗に結ばれていないものとこの店舗の attention のものを、参照が無ければ event と同じ transaction で消す。途中で止まっても、再実行で
        # 残りの工程を続ける。この run の始めに購読が既に解約済みで顧客も既に消えていれば、前の run が待機まで済ませたものとして待機を省く
        # (解約の event は前の run の後片付けで消えている)。購入が無ければ(purge と同じく always で呼ばれる)何もせずに skipped。DB の例外は
        # 工程の語(店舗と購読の読み取り lookup_failed、顧客の削除の前の確かめ release_failed、待機 wait_failed、後片付け cleanup_failed)に、
        # 残りの例外(Checkout::Client が包まない接続の切断など。SystemExit と signal は StandardError でないので捕まえない)は cancel_error に
        # 写し、例外の文を出さずに断りの 1 行で止める。
        module Cancel
          LABEL = 'GROWTH_CANCEL'
          WAIT = 120
          DELETED = 'customer.subscription.deleted'
          UNSETTLED = %w[open payment_pending].freeze
          TERMINAL = %w[completed attention].freeze
          INFLIGHT = %w[pending queued processing].freeze

          module_function

          def call(prefix)
            account = Target.purchased!(prefix)
            return line(prefix, 'skipped', nil, 0, 'no_purchase') unless account

            refuse!(prefix, account, 'key_not_test') unless GrowthLive.key.match?(KEY_FORMAT)
            client = Toybaco::Checkout::Client.new(GrowthLive.key)
            id = Target.subscription_id!(prefix, account, client)
            return line(prefix, 'skipped', account.id, 0, 'no_purchase') unless id

            settle!(prefix, account, client, Target.subscription!(prefix, account, client, id))
            line(prefix, 'canceled', account.id, cleanup!(prefix, account, id), NONE)
          rescue StandardError
            refuse!(prefix, account, 'cancel_error')
          end

          # 購読を解約し(既に解約済みなら省く)、顧客を消して(既に消えていれば省く)、解約の event の終端と処理中の event が無くなるのを待つ。
          # この run の始めに購読が解約済みで顧客も消えていれば、前の run が待機まで済ませたものとして待たない(解約の event は前の run の
          # 後片付けで消えている)。それ以外(この run で解約したか顧客を消した)は待つ(wait!)。
          def settle!(prefix, account, client, subscription)
            id = subscription.fetch('id')
            canceled = subscription['status'] == 'canceled'
            cancel!(prefix, account, client, id) unless canceled
            wait!(prefix, account, id) unless Customer.delete!(prefix, account, client, subscription) && canceled
          end

          # 解約の event が終端になり(deleted?)、この run の id を reference_id に持つ処理中の event が無くなるまで、同じ予算(WAIT 秒)で待つ。
          # 処理中の event を残して後片付けすると、後で終端になった event が残り、毎分の sweep が知らせ続ける。待っても終わらなければ
          # webhook_timeout で止める。
          def wait!(prefix, account, subscription_id)
            references = references(account, subscription_id)
            settled = GrowthLive.wait_until(WAIT) { deleted?(subscription_id) && !inflight?(references) }
            refuse!(prefix, account, 'webhook_timeout') unless settled
          rescue ActiveRecord::ActiveRecordError
            refuse!(prefix, account, 'wait_failed')
          end

          def inflight?(references)
            Toybaco::BillingEvent.exists?(mode: MODE, state: INFLIGHT, reference_id: references)
          end

          # 解約する店舗と購読を選ぶ。店舗と購入の記録の読み取りの DB の例外は lookup_failed に写す。
          module Target
            module_function

            def purchased!(prefix)
              stores = E2eConsent.accounts(prefix)
              refuse!(prefix, nil, 'name_format') unless stores.all? { |store| store.name.match?(E2eConsent::RUN_NAME_FORMAT) }
              purchased = stores.select { |store| purchase?(Toybaco::Growth::PurchaseIntent.saved(store)) }
              refuse!(prefix, nil, 'multiple_purchases') if purchased.size > 1
              purchased.first
            rescue ActiveRecord::ActiveRecordError
              refuse!(prefix, nil, 'lookup_failed')
            end

            # 購入の記録が complete か、Session のある未完了(open / payment_pending)。
            def purchase?(saved)
              return false unless saved.is_a?(Hash)

              saved['state'] == 'complete' || (UNSETTLED.include?(saved['state']) && saved['session_id'].present?)
            end

            # 解約する購読の id。complete なら店舗の契約の購読(無ければ subscription_missing)、未完了なら Stripe の Session の購読(Session が
            # 完了していなければ nil)。
            def subscription_id!(prefix, account, client)
              saved = Toybaco::Growth::PurchaseIntent.saved(account)
              return session_subscription!(prefix, account, client, saved['session_id']) unless saved['state'] == 'complete'

              id = Toybaco::Entitlements.attributes(account)['toybaco_subscription_id']
              return id if id.to_s.match?(SUBSCRIPTION_FORMAT)

              refuse!(prefix, account, 'subscription_missing')
            rescue ActiveRecord::ActiveRecordError
              refuse!(prefix, account, 'lookup_failed')
            end

            def session_subscription!(prefix, account, client, session_id)
              session = client.retrieve_checkout_session(session_id)
              session['subscription'] if session['status'] == 'complete' && session['subscription'].to_s.match?(SUBSCRIPTION_FORMAT)
            rescue Toybaco::Checkout::Error
              refuse!(prefix, account, 'session_unavailable')
            end

            # 購読を Stripe から読み、test mode でこの店舗の購入の購読(metadata の店舗 id)であることを確かめる。
            def subscription!(prefix, account, client, id)
              subscription = client.retrieve_subscription(id)
              return subscription if own?(account, id, subscription)

              refuse!(prefix, account, 'subscription_mismatch')
            rescue Toybaco::Checkout::Error => e
              refuse!(prefix, account, e.message == 'stripe 404' ? 'subscription_missing' : 'subscription_unavailable')
            end

            # test mode の、この店舗の購入の購読(PurchaseForm が Session と購読の metadata に入れる店舗 id が一致する)。
            def own?(account, id, subscription)
              metadata = subscription['metadata'].is_a?(Hash) ? subscription['metadata'] : {}
              subscription['id'] == id && subscription['livemode'] == false && metadata['toybaco_existing_account_id'] == account.id.to_s
            end

            def refuse!(prefix, account, reason)
              Cancel.refuse!(prefix, account, reason)
            end
          end

          # 解約の応答が、この購読(id)の test mode の解約済みでなければ止める。
          def cancel!(prefix, account, client, id)
            canceled = client.cancel_unpaid_subscription(id)
            refuse!(prefix, account, 'cancel_failed') unless canceled.values_at('id', 'status', 'livemode') == [id, 'canceled', false]
          rescue Toybaco::Checkout::Error
            refuse!(prefix, account, 'cancel_failed')
          end

          # 購読の顧客を消す(既に消えていれば何もしない)。顧客の削除はその顧客の有効な購読を全て解約するため、この run の外の購読を巻き込まない
          # ことを確かめられなければ、消さずに customer_mismatch で止める。
          module Customer
            KEY = "internal_attributes ->> 'toybaco_stripe_customer_id' = ?"

            module_function

            # この run の前に既に消えていれば何もせずに true、この run で消せば false を返す。
            def delete!(prefix, account, client, subscription)
              api = ApiHandler.new(GrowthLive.key)
              customer = customer!(prefix, account, api, subscription['customer'].to_s)
              return true if customer['deleted'] == true

              refuse!(prefix, account, 'customer_mismatch') unless sole?(api, client, account, customer, subscription.fetch('id'))
              refuse!(prefix, account, 'customer_delete_failed') unless api.delete_customer(customer['id'])['deleted'] == true
              false
            rescue ApiHandler::Failure
              refuse!(prefix, account, 'customer_delete_failed')
            rescue ActiveRecord::ActiveRecordError
              refuse!(prefix, account, 'release_failed')
            end

            def customer!(prefix, account, api, customer_id)
              customer = api.retrieve_customer(customer_id)
              return customer if customer['id'] == customer_id

              refuse!(prefix, account, 'customer_mismatch')
            rescue ApiHandler::Failure
              refuse!(prefix, account, 'customer_mismatch')
            end

            # test mode で契約者(購入の記録の owner)のメールの顧客で、この店舗の購入の顧客(purchased_by?)で、DB でほかの店舗がこの顧客を契約に
            # 持たず、Stripe でこの顧客の購読がこの購読だけ(解約済みを含む全件)。
            def sole?(api, client, account, customer, subscription_id)
              owned?(account, customer) && purchased_by?(client, account, customer['id']) &&
                Account.where(KEY, customer['id']).where.not(id: account.id).none? && only_subscription?(api, customer['id'], subscription_id)
            end

            # この店舗の購入の記録の Session の顧客(同じメールのほかの店舗・ほかの run の顧客ではない直接の証拠)で、購入の記録が complete なら
            # 店舗の契約の顧客とも同じ。Session を読めなければ確かめられないとする。
            def purchased_by?(client, account, customer_id)
              saved = Toybaco::Growth::PurchaseIntent.saved(account)
              contract = saved['state'] != 'complete' || Toybaco::Entitlements.attributes(account)['toybaco_stripe_customer_id'] == customer_id
              contract && client.retrieve_checkout_session(saved['session_id'].to_s)['customer'] == customer_id
            rescue Toybaco::Checkout::Error
              false
            end

            def owned?(account, customer)
              owner = User.find_by(id: Toybaco::Growth::PurchaseIntent.saved(account)&.fetch('owner_id', nil))
              email = owner ? owner.email.to_s.downcase : ''
              email.present? && customer['livemode'] == false && customer['email'].to_s.downcase == email
            end

            def only_subscription?(api, customer_id, subscription_id)
              listed = api.list_subscriptions(customer_id)
              data = listed['data'].is_a?(Array) ? listed['data'] : []
              listed['has_more'] == false && data.map { |item| item.is_a?(Hash) ? item['id'] : nil } == [subscription_id]
            rescue ApiHandler::Failure
              false
            end

            def refuse!(prefix, account, reason)
              Cancel.refuse!(prefix, account, reason)
            end
          end

          # 解約の event(customer.subscription.deleted)が Rails で終端(completed・attention)になった。店舗に結べない購読でも、結べた購読の
          # 処理が止まっても、attention で終わりうるため、どちらの経路でも attention を終端と見なす(止まった依頼は後片付けが手放す)。
          def deleted?(subscription_id)
            Toybaco::BillingEvent.where(action: 'subscription_notice', reference_id: subscription_id, mode: MODE, state: TERMINAL)
                                 .exists?(["snapshot ->> 'type' = ?", DELETED])
          end

          # この run の id(購入の記録の Session と購読。形の合う値だけ)を reference_id に持つ終端の event(completed・attention。解約の event
          # も含む)を全て消して件数を返す(attention の行を残すと毎分の sweep が知らせ続ける)。処理中の event(pending・queued・processing)と
          # 更新の請求書の記録が結ぶ event は残す。続けて、この購読の同期の依頼のうち、毎分の sweep が知らせ続ける止まった依頼を手放す
          # (release_request!。消した event の結びが外れた後に確かめる)。2 つの削除は 1 つの transaction で行い、FK の競合などで後ろが
          # 失敗すれば両方を戻す(再実行がやり直す)。
          def cleanup!(prefix, account, subscription_id)
            references = references(account, subscription_id)
            facts = Toybaco::RenewalInvoiceFact.where.not(billing_event_id: nil).select(:billing_event_id)
            Toybaco::BillingEvent.transaction do
              events = Toybaco::BillingEvent.where(mode: MODE, state: TERMINAL, reference_id: references).where.not(id: facts).delete_all
              release_request!(account, subscription_id)
              events
            end
          rescue ActiveRecord::ActiveRecordError
            refuse!(prefix, account, 'cleanup_failed')
          end

          # この run の id(購入の記録の Session と購読。形の合う値だけ)。
          def references(account, subscription_id)
            saved = Toybaco::Growth::PurchaseIntent.saved(account) || {}
            [[saved['session_id'], SESSION_FORMAT], [subscription_id, SUBSCRIPTION_FORMAT]]
              .filter_map { |value, format| value if value.to_s.match?(format) }
          end

          # 毎分の sweep が知らせ続ける止まった同期の依頼を手放す。対象は、店舗に結ばれていない(account_id が NULL の)依頼と、この店舗に
          # 結ばれて attention で止まった依頼だけ(E2E の店舗は後で purge されるので、店舗の停止の処理は失われない)。この店舗の completed・
          # pending・running の依頼とほかの店舗の依頼には触らない(遅れて店舗に結ばれた依頼の停止の処理を消さない)。ほかの event から FK で
          # 参照されていなければ消し、消した件数を返す(参照が残れば消さない)。
          def release_request!(account, subscription_id)
            scope = Toybaco::SubscriptionSyncRequest.where(subscription_id: subscription_id, mode: MODE)
            requests = scope.where(account_id: nil).or(scope.where(account_id: account.id, state: 'attention'))
            bound = Toybaco::BillingEvent.where.not(subscription_sync_request_id: nil).select(:subscription_sync_request_id)
            requests.where.not(id: bound).delete_all
          end

          def line(prefix, result, account_id, events, reason)
            "TOYBACO_E2E_#{LABEL} prefix=#{prefix} result=#{result} account=#{account_id || NONE} events=#{events} reason=#{reason}"
          end

          def refuse!(prefix, account, reason)
            GrowthLive.stop!(line(prefix, 'refused', account&.id, 0, reason))
          end
        end
      end

      # toybaco:e2e_purge_billing の本体。店舗が消えた後に残った E2E の課金の記録(e2e_purge_accounts が店舗の購入と契約から辿れなくなった
      # 孤児。毎分の sweep が TOYBACO_BILLING_ATTENTION / TOYBACO_SUBSCRIPTION_SYNC_ATTENTION を出し続ける)を、Stripe test mode で E2E の購入と
      # 確かめてから消す。候補は test mode の行だけで、(i) どの店舗の購入の記録の Session でも規約同意の記録の Session でもない(同意の記録は
      # 追記だけなので、購入をやり直した店舗の前の Session も外れる)終端(completed・attention。result は問わない。
      # purge が残した処理中の購入は、店舗が消えた後に record_missing のほか期限・試行の上限の result で attention になる)の growth_checkout の
      # event、(ii) どの店舗の契約にも無い購読の終端の通知の event、(iii) 店舗に結ばれていないか、消えた店舗に結ばれた attention の同期の依頼で、
      # 購読がどの店舗の契約にも無いもの(処理中の行・更新の請求書の記録と開通の受付に結ばれた event は候補にしない)。候補の行数に上限は
      # 置かず、event と依頼をまとめて新しい順(作成時刻の降順、同じ時刻は id の降順)に並べた照合する一意の id(Session・購読)が
      # MAX_LOOKUPS 件以下なら全てを照合する。超えるときは、件数を SHARD_SIZE で割って切り上げた数の shard に分け(所属は id の SHA-256 の
      # 先頭 8 桁で決まり、id が増減しても shard の数が変わらない限り動かない)、同じ prefix のこの task の過去の実行回数(監査行のうち
      # 終わりの行 ok / failed で、params_digest が今の prefix のもの)を shard の数で割った余りの shard だけを、新しい順に MAX_LOOKUPS 件まで
      # 照合する(呼び出しごとに shard が回るので、照合できない id が溜まっても古い孤児に届く)。選ばなかった shard の行と予算で届かなかった
      # 行の数を remaining に出す。候補ごとに Stripe の Session を GrowthLive::ApiHandler で読み(Session は retrieve、購読はそれを作った Session の
      # 一覧。どちらも購読と、その既定の PaymentMethod を展開する。同じ id は 1 回)、応答が照合する id に結び付き(読んだ Session の id が照合する
      # Session の id、購読の一覧は続きの無い 1 件で、その Session の購読が照合する購読)、Session が test mode の完了した Checkout Session で、
      # 購入者のメール(customer_email と customer_details.email の空でないもの。両方あれば同じ)が全て E2E の固定メールの形、metadata の店舗
      # (toybaco_existing_account_id)が DB に無く、購入者の名前(customer_details.name と、購読の既定の PaymentMethod の請求先の名前。E2E の
      # rake は請求先の名前に店舗名 = run 名を入れる)の空でないものが 1 つ以上あって全て同じで、E2E の run 名の形(RUN_NAME_FORMAT)に合い
      # prefix で始まるときだけ、その範囲の E2E の購入と見なす(E2E の購入者のメールは全 run で同じなので、run への結び付けは名前で行う)。
      # 照合に失敗した候補と、Stripe が 404 かほかの 4xx を返した候補は消さずに unverified に数える(fail-closed)。401 / 403 は
      # stripe_unauthorized、429・5xx と応答の無い失敗(接続・timeout・本文の破損)は stripe_unavailable で、その時点で Stripe を呼ぶのをやめ、
      # 何も消さずに止める。照合を全て済ませてから、1 つの transaction で候補の条件と照合した id を読み直して(行ロック)消す。順は event、依頼
      # (event から FK で参照されている依頼は残す)。候補が 0 件なら Stripe を呼ばない。
      # 鍵の検査は GrowthLive と同じ(KEY_FORMAT。sk_test_ / rk_test_)。出力は 1 行(消した件数・unverified・remaining)で、id・メール・
      # 金額・鍵・例外の文は出さない。
      module Orphans
        LABEL = 'TOYBACO_E2E_PURGE_BILLING_ORPHANS'
        # 1 回の呼び出しで Stripe で照合する一意の id(Session・購読)の上限。
        MAX_LOOKUPS = 100
        # 照合する id が MAX_LOOKUPS を超えるときの、1 つの shard の id の数の目安(shard の数 = 件数 / SHARD_SIZE の切り上げ)。
        SHARD_SIZE = 50
        # この task の監査行の action(RakeAudit が書く。過去の実行回数はこの action の終わりの行 ok / failed の数)。
        AUDIT_ACTION = 'rake.toybaco:e2e_purge_billing'
        # 鍵の権限の不足を表す HTTP の status code(stripe_unauthorized で止める)。
        UNAUTHORIZED = %w[401 403].freeze
        STORE_ID = /\A[1-9]\d{0,19}\z/
        # Account の id(PostgreSQL の bigint)の範囲。外れる値は exists? が RangeError を投げるので、照合できないとして扱う。
        STORE_ID_RANGE = (1..9_223_372_036_854_775_807)
        CONTRACT = "internal_attributes ->> 'toybaco_subscription_id'"
        # 照合する id の形(Session と購読。GrowthLive::Cancel の後片付けと同じ検査)。
        REFERENCE = Regexp.union(GrowthLive::SESSION_FORMAT, GrowthLive::SUBSCRIPTION_FORMAT)

        module_function

        # toybaco:e2e_purge_billing[prefix]。
        def run(args)
          staging!('e2e_purge_billing')
          E2eBilling.require_billing!
          call(E2eConsent.prefix!(args))
        end

        def staging!(task)
          E2eConsent.staging!(task)
        end

        def call(prefix)
          refuse!(prefix, 'key_not_test') unless GrowthLive.key.match?(GrowthLive::KEY_FORMAT)
          found = candidates
          references = window(found.pluck(2).uniq, prefix)
          picked = found.select { |row| references.include?(row[2]) }
          events, requests = picked.empty? ? [0, 0] : delete!(Lookup.verified(prefix, references, picked))
          "#{LABEL} prefix=#{prefix} events=#{events} requests=#{requests} unverified=#{picked.size - events - requests} " \
            "remaining=#{found.size - picked.size}"
        rescue ActiveRecord::ActiveRecordError
          refuse!(prefix, 'billing_failed')
        rescue StandardError
          refuse!(prefix, 'purge_error')
        end

        # [種類, 行の id, 照合する id, 作成時刻] の配列。event と依頼をまとめて新しい順(作成時刻の降順、同じ時刻は id の降順)。照合する id の
        # 形が合わない行は候補にしない。
        def candidates
          events = orphan_events.pluck(:id, :reference_id, :created_at).map { |id, reference, at| [:event, id, reference, at] }
          requests = orphan_requests.pluck(:id, :subscription_id, :created_at).map { |id, reference, at| [:request, id, reference, at] }
          rows = (events + requests).select { |_, _, reference, _| reference.match?(REFERENCE) }
          rows.sort_by { |kind, id, _, at| [at, id, kind.to_s] }.reverse
        end

        # 照合する id(新しい順)。MAX_LOOKUPS 件以下なら全て。超えるときは、同じ prefix の実行回数で選んだ shard の id を新しい順に
        # MAX_LOOKUPS 件まで。
        def window(references, prefix)
          return references if references.size <= MAX_LOOKUPS

          shards = (references.size / SHARD_SIZE.to_f).ceil
          selected = runs(prefix) % shards
          references.select { |reference| shard(reference, shards) == selected }.first(MAX_LOOKUPS)
        end

        # id の所属する shard(id の SHA-256 の先頭 8 桁を整数にして shard の数で割った余り)。Toybaco::Ops::Digest に隠れないよう ::Digest。
        def shard(reference, shards)
          ::Digest::SHA256.hexdigest(reference)[0, 8].to_i(16) % shards
        end

        # 同じ prefix のこの task の過去の実行回数(監査行のうち終わりの行の数。今の実行の started は数えない)。params_digest は RakeAudit が
        # 引数(余分な引数が無いときは args.to_h の { prefix: }) から Ops::Audit.params_digest で組むものと同じ。
        def runs(prefix)
          digest = Toybaco::Ops::Audit.params_digest({ prefix: prefix })
          Toybaco::OperatorAction.where(action: AUDIT_ACTION, result: %w[ok failed], params_digest: digest).count
        end

        def orphan_events
          records = E2eConsent::Purge::BillingRecords
          scope = Toybaco::BillingEvent.where(mode: MODE, opening_request_id: nil, state: records::TERMINAL).where.not(id: records.facts)
          checkout = scope.where(action: 'growth_checkout').where.not(reference_id: purchased).where.not(reference_id: consented)
          checkout.or(scope.where(action: 'subscription_notice').where.not(reference_id: contracted))
        end

        def orphan_requests
          scope = Toybaco::SubscriptionSyncRequest.where(mode: MODE).where.not(state: E2eConsent::Purge::BillingRecords::RUNNING)
          scope = scope.where.not(subscription_id: contracted)
          scope.where(account_id: nil).or(scope.where(state: 'attention').where.not(account_id: Account.select(:id)))
        end

        # どれかの店舗の契約(internal_attributes の toybaco_subscription_id)にある購読の id。
        def contracted
          Account.where("#{CONTRACT} IS NOT NULL").select(Arel.sql(CONTRACT))
        end

        # どれかの店舗の規約同意の記録(internal_attributes の LegalTerms::KEY。追記だけの配列)にある Session の id(NULL は含めない)。
        def consented
          consents = "accounts.internal_attributes -> #{Account.connection.quote(Toybaco::LegalTerms::KEY)}"
          entries = "CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(#{consents}) = 'array' THEN #{consents} " \
                    "ELSE '[]'::jsonb END) AS consent"
          Account.joins(entries).where("consent ->> 'session_id' IS NOT NULL").select(Arel.sql("consent ->> 'session_id'"))
        end

        # どれかの店舗の購入の記録(internal_attributes の PurchaseIntent::KEY)にある Session の id。
        def purchased
          column = "internal_attributes -> #{Account.connection.quote(Toybaco::Growth::PurchaseIntent::KEY)} ->> 'session_id'"
          Account.where("#{column} IS NOT NULL").select(Arel.sql(column))
        end

        # Stripe での照合(照合する id ごとに Session を読み、E2E の購入の Session か確かめる)。止める失敗は Orphans.refuse!。
        module Lookup
          module_function

          # 照合する id を走査の順に Stripe で読み、E2E の購入の Session と確かめられた候補を返す。
          def verified(prefix, references, picked)
            api = GrowthLive::ApiHandler.new(GrowthLive.key)
            results = references.index_with { |reference| e2e_session?(prefix, session(prefix, api, reference)) }
            picked.select { |row| results.fetch(row[2]) }
          end

          # 照合する id に結び付いた Stripe の Session。結び付かない応答と、404・ほかの 4xx は nil(照合できない)。止める失敗は http_failure。
          def session(prefix, api, reference)
            return own_session(reference, api.checkout_session(reference)) if reference.match?(GrowthLive::SESSION_FORMAT)

            listed_session(reference, api.subscription_sessions(reference))
          rescue GrowthLive::ApiHandler::Failure => e
            http_failure(prefix, e.status)
          rescue SystemCallError, IOError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError
            refuse!(prefix, 'stripe_unavailable')
          end

          # retrieve で読んだ Session が、照合する Session の id のもの。
          def own_session(reference, session)
            session if session.is_a?(Hash) && session['id'] == reference
          end

          # 購読の Session の一覧が続きの無いちょうど 1 件で、その Session の購読(文字列か、展開された object の id)が照合する購読。
          def listed_session(reference, listed)
            data = listed.is_a?(Hash) && listed['has_more'] == false ? Array(listed['data']) : []
            session = data.first if data.size == 1
            return unless session.is_a?(Hash)

            subscription = session['subscription']
            session if (subscription.is_a?(Hash) ? subscription['id'] : subscription) == reference
          end

          # HTTP の失敗の区分。404 とほかの 4xx は照合できない(nil)。401 / 403 は stripe_unauthorized、429・5xx・ほかの status と、status の
          # 無い失敗(応答の無い失敗)は stripe_unavailable で、何も消さずに止める(再試行すべき状態の候補を unverified に落とさない)。
          def http_failure(prefix, code)
            return refuse!(prefix, 'stripe_unauthorized') if UNAUTHORIZED.include?(code)
            return if code.to_s.match?(/\A4\d\d\z/) && code != '429'

            refuse!(prefix, 'stripe_unavailable')
          end

          # test mode の完了した Checkout Session で、購入者のメールが E2E の固定メールの形、metadata の店舗が DB に無く、購入者の名前が
          # prefix の範囲の E2E の run 名。
          def e2e_session?(prefix, session)
            return false unless session.is_a?(Hash) && session['livemode'] == false
            return false unless session.values_at('object', 'status') == %w[checkout.session complete]

            details = session['customer_details'].is_a?(Hash) ? session['customer_details'] : {}
            e2e_email?(session['customer_email'], details['email']) && gone?(session['metadata']) &&
              run_named?(prefix, details['name'], billing_name(session['subscription']))
          end

          # 購入者のメール(customer_email と customer_details.email のうち空でないもの)が 1 つ以上あり、全て E2E の固定メールの形で、互いに同じ。
          def e2e_email?(*values)
            emails = values.reject { |value| value.nil? || value == '' }
            emails.any? && emails.uniq.size == 1 && emails.all? { |email| email.is_a?(String) && email.match?(E2eConsent::EMAIL_FORMAT) }
          end

          # metadata の店舗 id(PurchaseForm が入れる toybaco_existing_account_id)が bigint の範囲の正の整数で、その店舗が DB に無い。
          def gone?(metadata)
            store = metadata.is_a?(Hash) ? metadata['toybaco_existing_account_id'].to_s : ''
            id = store.match?(STORE_ID) ? Integer(store, 10) : 0
            STORE_ID_RANGE.cover?(id) && !Account.exists?(id: id)
          end

          # 購入者の名前(customer_details.name と購読の既定の PaymentMethod の請求先の名前のうち空でないもの)が 1 つ以上あり、全て同じで、
          # E2E の run 名の形(RUN_NAME_FORMAT)に合い、prefix で始まる。名前が取れない・食い違う・形違い・prefix の外は照合できない。
          def run_named?(prefix, *values)
            names = values.reject { |value| value.nil? || value == '' }
            names.any? && names.uniq.size == 1 && run_name?(prefix, names.first)
          end

          # E2E の run 名の形(RUN_NAME_FORMAT)に合い、prefix で始まる文字列。
          def run_name?(prefix, name)
            name.is_a?(String) && name.match?(E2eConsent::RUN_NAME_FORMAT) && name.start_with?(prefix)
          end

          # 展開された購読の既定の PaymentMethod の請求先の名前(展開されていない・無いときは nil)。
          def billing_name(subscription)
            method = subscription['default_payment_method'] if subscription.is_a?(Hash)
            details = method['billing_details'] if method.is_a?(Hash)
            details['name'] if details.is_a?(Hash)
          end

          def refuse!(prefix, reason)
            Orphans.refuse!(prefix, reason)
          end
        end

        # 照合できた候補を、1 つの transaction で候補の条件と照合した id を読み直して(行ロック)から消す。event、依頼の順(依頼は event の参照が
        # 外れた後に確かめ、参照が残れば消さない)。消した event と依頼の件数を返す。
        def delete!(verified)
          records = E2eConsent::Purge::BillingRecords
          ActiveRecord::Base.transaction do
            events = records.remove!(bound_rows(orphan_events, verified, :event, :reference_id))
            requests = records.remove!(bound_rows(orphan_requests, verified, :request, :subscription_id).where.not(id: records.bound))
            [events.size, requests.size]
          end
        end

        # 照合した候補の行のうち、照合した id が今も同じもの(照合した id ごとに where(id:, 列: 照合した id))。候補が無ければ空。
        def bound_rows(scope, verified, kind, column)
          groups = verified.select { |row| row[0] == kind }.group_by { |row| row[2] }
          groups.map { |reference, rows| scope.where(id: rows.pluck(1)).where(column => reference) }.reduce(:or) || scope.none
        end

        def refuse!(prefix, reason)
          GrowthLive.stop!("#{LABEL} prefix=#{prefix} result=refused account=#{NONE} reason=#{reason}")
        end
      end
    end
  end
end

namespace :toybaco do
  desc 'staging 専用: 体験の後の E2E の店舗(ちょうど 1 件)を、Stripe を呼ばない偽 client で本番の購入の処理を通して Standard(月払い)に' \
       'する(rake "toybaco:e2e_growth_purchase[e2e-consent-<run>]")'
  task :e2e_growth_purchase, %i[prefix] => :environment do |_t, args|
    puts Toybaco::Ops::E2eBilling.growth_purchase(args)
  end

  desc 'staging 専用: E2E の店舗(ちょうど 1 件)の契約者のメールで、Stripe を呼ばない偽 client で本番の開通の処理を通し、同じ名前の店舗を' \
       '作る(rake "toybaco:e2e_opening_checkout[e2e-consent-<run>]")'
  task :e2e_opening_checkout, %i[prefix] => :environment do |_t, args|
    puts Toybaco::Ops::E2eBilling.opening_checkout(args)
  end

  desc 'staging 専用: 体験の後の E2E の店舗(ちょうど 1 件)を、Stripe test mode の実経路(Checkout Session → 決済 → webhook → 本番の購入の' \
       '処理)で Standard(月払い)にする(rake "toybaco:e2e_growth_purchase_live[e2e-consent-<run>]")'
  task :e2e_growth_purchase_live, %i[prefix] => :environment do |_t, args|
    puts Toybaco::Ops::E2eBilling.growth_purchase_live(args)
  end

  desc 'staging 専用: e2e_growth_purchase_live で買った E2E の店舗の購読を Stripe test mode で解約して顧客を消し、この run の完了した ' \
       'event を消す(rake "toybaco:e2e_growth_cancel[e2e-consent-<run>]")'
  task :e2e_growth_cancel, %i[prefix] => :environment do |_t, args|
    puts Toybaco::Ops::E2eBilling.growth_cancel(args)
  end

  desc 'staging 専用: 店舗が消えた後に残った E2E の課金の記録(終端の event・止まった同期の依頼。1 回 50 件まで)を、Stripe test mode で E2E の' \
       '購入と確かめてから消す(rake "toybaco:e2e_purge_billing[e2e-consent-r]")'
  task :e2e_purge_billing, %i[prefix] => :environment do |_t, args|
    puts Toybaco::Ops::E2eBilling::Orphans.run(args)
  end
end

# staging の E2E(無料登録の hCaptcha)用。staging の InstallationConfig の HCAPTCHA_SITE_KEY / HCAPTCHA_SERVER_KEY に、hCaptcha 公式の公開
# test 鍵(公開ドキュメントの定数で秘密ではない)を入れ(on)、空にし(off)、分類を表示する(show)。test 鍵の入った staging では、無料登録の
# E2E(tests/staging/80-consent-free-signup.js)がウィジェットのチェックを押して token を得てから送信するため、CSP が hCaptcha の iframe を
# 塞ぐ退行を staging で検出できる。staging 専用で、環境の判定は E2eConsent と同じ(production と環境が不明なときは引数を読む前に abort する。
# ops-rake workflow も e2e_ で始まるタスクを staging 以外では拒否する。二重の fail-closed)。on / off は 1 つの transaction(外側の
# transaction の中で呼ばれても savepoint を作る)で、同じ rake の同時実行を advisory lock で直列にしてから 2 行を行ロックして読み、
# 行の値と同じ名前の環境変数(行が無いと GlobalConfigService.load が環境変数から行を作る)のどれかに実鍵(空でも test 定数でもない値。
# foreign)があれば何も書かずに abort する(staging の実鍵を上書きしない)。書いた後に同じ transaction で読み直した分類を出し、commit の後に
# だけ GlobalConfig の cache を消す。出力は分類(empty / test / foreign)だけで、鍵の値(test 定数を含む)は出さない。監査行
# (started / ok|failed)は上の RakeAudit が書く。rake は Rails の初期化前にこのファイルを読むため、モデルは実行時に参照する。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    module E2eCaptcha
      TEST_SITE_KEY = '10000000-ffff-ffff-ffff-000000000001'
      TEST_SECRET = '0x0000000000000000000000000000000000000000'
      # 出力の項目名 → [InstallationConfig の行名(同じ名前の環境変数), その行の test 定数]。出力の順もこの順。
      KEYS = { 'site_key' => ['HCAPTCHA_SITE_KEY', TEST_SITE_KEY], 'server_key' => ['HCAPTCHA_SERVER_KEY', TEST_SECRET] }.freeze
      MODES = %w[on off show].freeze

      module_function

      def staging!(task)
        E2eConsent.staging!(task)
      end

      # toybaco:e2e_captcha_test_keys[mode]。show は読むだけ。on / off は書いて読み直した分類の 1 行を返す。
      def run(args)
        staging!('e2e_captcha_test_keys')
        mode = mode!(args)
        return line(mode, current) if mode == 'show'

        # 外側の transaction の中で呼ばれても、例外のときに 2 行とも戻るよう savepoint を作る(requires_new)。例外と abort のときは値が
        # 変わらないので cache も消さない。
        written = InstallationConfig.transaction(requires_new: true) { write!(mode) }
        # 行の after_commit も cache を消すが、読み手(GlobalConfigService.load)に古い値が残らないよう commit の後にも消す。
        GlobalConfig.clear_cache
        written
      end

      # 検査と代入を同じ判定にする(通すのは on / off / show の文字列 1 つだけで、Symbol や余分な引数は通さない)。入力の値は出さない。
      def mode!(args)
        mode = args[:mode]
        return mode if mode.is_a?(String) && MODES.include?(mode) && args.extras.empty?

        abort 'TOYBACO_E2E_CAPTCHA_ABORT reason=mode_invalid'
      end

      # transaction の中で呼ぶ。最初に同じ rake の同時実行を transaction の終わりまで直列にする(行が無いときに両方が行を作ろうとして、
      # 後の方が unique index の違反で落ちない。後の実行は先の実行が確定させた行を読む)。続けて 2 行を行ロックして(行が無ければ作る用意を
      # して)、行の値と環境変数を分類し、foreign があれば何も書かずに abort する。on は test 定数、off は空文字を入れ(行は消さない)、
      # SuperAdmin の設定画面で編集できるよう locked: false にする(上流の既定値と同じ)。
      def write!(mode)
        InstallationConfig.connection.execute("SELECT pg_advisory_xact_lock(hashtext('toybaco_e2e_captcha_test_keys'))")
        rows = locked_rows
        abort 'TOYBACO_E2E_CAPTCHA_ABORT reason=foreign_keys' if classes(rows.transform_values(&:value)).value?('foreign')

        rows.each do |key, row|
          row.value = mode == 'on' ? KEYS.fetch(key).last : ''
          row.locked = false
          row.save!
        end
        line(mode, current)
      end

      # 2 行を行ロック(SELECT … FOR UPDATE)付きで読む。行が無ければ保存前の新しい行にする。transaction の中で呼ぶ。
      def locked_rows
        KEYS.transform_values { |(name, _)| InstallationConfig.lock.find_or_initialize_by(name: name) }
      end

      # 読み手の DB の値(行が無ければ nil)と環境変数の分類。GlobalConfigService.load は環境変数から行を作ることがあるため使わない。
      def current
        classes(KEYS.transform_values { |(name, _)| InstallationConfig.find_by(name: name)&.value })
      end

      # 行の値の分類に、同じ名前の環境変数の分類を重ねる。どちらかが foreign なら foreign、そうでなければ行の分類(環境変数が空か test
      # 定数なら行の分類のまま)。GlobalConfigService.load は行が無いと環境変数から行を作るため、行だけを見ると実鍵を取りこぼす。
      def classes(values)
        values.to_h do |key, value|
          name, test_value = KEYS.fetch(key)
          found = [classify(value, test_value), classify(ENV.fetch(name, nil), test_value)]
          [key, found.include?('foreign') ? 'foreign' : found.first]
        end
      end

      # 空(nil か空文字)は empty、その行の test 定数と一致すれば test、ほかは全て foreign(空白だけの値・型の違う値・もう一方の行の test
      # 定数も、実鍵と同じく上書きしない)。
      def classify(value, test_value)
        return 'empty' if value.nil? || value == ''

        value == test_value ? 'test' : 'foreign'
      end

      def line(mode, found)
        "TOYBACO_E2E_CAPTCHA mode=#{mode} site_key=#{found.fetch('site_key')} server_key=#{found.fetch('server_key')}"
      end
    end
  end
end

namespace :toybaco do
  desc 'staging 専用: 無料登録の E2E 用に hCaptcha 公式の公開 test 鍵を入れる・空にする・分類を表示する(実鍵があれば書かない)' \
       '(rake "toybaco:e2e_captcha_test_keys[on|off|show]")'
  task :e2e_captcha_test_keys, %i[mode] => :environment do |_t, args|
    puts Toybaco::Ops::E2eCaptcha.run(args)
  end
end

# Postiz の利用者の解放(toybaco:postiz_identity_release[chatwoot_user_id])。担当者を削除して同じメールアドレスで追加し直すと、
# 削除前の Chatwoot user に結び付いた Postiz の GENERIC 利用者が同じ email のまま残り、新しい担当者の同期(PostizMembershipJob)が
# IdentityConflict で止まる。この task はその行の email を tombstone(<local>+released-<unix 秒>-<chatwoot user id>@<domain>)にして解放し、新しい担当者の
# 同期を積み直す。判定と書き込みは Toybaco::PostizSync.release_conflicting_identity! が新しい担当者の identity lock の下で行い
# (email の書き換えは削除時の解放と同じ PostizSync.release_identity!)、旧 Chatwoot user が残っている・旧行に有効な所属がある・
# 持ち主を確かめられない時は書かない(refused)。衝突の行が無ければ書かずに同期だけを積み直す(no-conflict の reason=none。解放の後に
# 積みそこねた時の経路で、2 回目の実行もこれになる)。投稿は organization に属するので、利用者の email の解放では変わらない。恒久対応(削除時の解放)までの運用の手当てで、両環境で使う
# (production は ops-rake の Environment 承認の後)。出力は 1 行で ID と状態だけを出し、メールアドレス・氏名は出さない。監査行
# (started / ok|failed)は上の RakeAudit が書く。rake は Rails の初期化前にこのファイルを読むため、モデル・ジョブ・PostizSync は実行時に参照する。
# Toybaco::Ops は先頭の RakeAudit で定義済み(このファイルの読み込み時に参照できる)。
module Toybaco::Ops::PostizIdentityRelease
  USER_ID_FORMAT = /\A[1-9]\d{0,9}\z/
  PREFIX = 'TOYBACO_POSTIZ_IDENTITY_RELEASE'
  # 同期を積む結果(state, reason)。解放した時と、衝突の行が無い時(解放の後に積みそこねた時の積み直し。job は冪等)。
  # 本人の行がある(same-user)・refused・found=false では積まない。
  REENQUEUE = [%w[released none], %w[no-conflict none]].freeze

  module_function

  # 新しい担当者が無ければ found=false。
  def run(args)
    user_id = user_id!(args)
    user = User.find_by(id: user_id)
    return "#{PREFIX} user=#{user_id} found=false" unless user

    result = Toybaco::PostizSync.release_conflicting_identity!(user: user)
    line(user_id, result, REENQUEUE.include?(result.values_at(:state, :reason)) && enqueue!(user))
  end

  # 検査と変換を同じ判定にする(通すのは 1 以上の整数の文字列 1 つだけで、Integer や余分な引数は通さない)。入力の値は出さない。
  def user_id!(args)
    raw = args[:chatwoot_user_id]
    return Integer(raw, 10) if raw.is_a?(String) && raw.match?(USER_ID_FORMAT) && args.extras.empty?

    abort "#{PREFIX}_ABORT reason=user_id_invalid"
  end

  # 既存の積み直し(PostizLifecycle の UserHooks)と同じく、Postiz を管理している店舗ごとに user id と店舗 id で積む。
  def enqueue!(user)
    accounts = Toybaco::PostizLifecycle.managed_accounts_for(user)
    accounts.each { |account| Toybaco::PostizMembershipJob.perform_later(user.id, account.id) }
    accounts.any?
  end

  # 旧行の Postiz id は先頭 8 字だけ。旧 Chatwoot user id は providerId から逆算できた時だけ出す。
  def line(user_id, result, enqueued)
    fields = { 'user' => user_id, 'old_postiz_user' => result[:postiz_user_id]&.slice(0, 8) || 'none',
               'old_chatwoot_user' => result[:chatwoot_user_id] || 'none', 'state' => result.fetch(:state),
               'reason' => result.fetch(:reason), 'enqueued' => enqueued }
    [PREFIX, *fields.map { |key, value| "#{key}=#{value}" }].join(' ')
  end
end

namespace :toybaco do
  desc 'Postiz の同期を止めている削除済み担当者の利用者行を解放し、新しい担当者の同期を積み直す' \
       '(rake "toybaco:postiz_identity_release[chatwoot_user_id]"。chatwoot_user_id は新しい担当者の 1 以上の整数)'
  task :postiz_identity_release, %i[chatwoot_user_id] => :environment do |_t, args|
    puts Toybaco::Ops::PostizIdentityRelease.run(args)
  end
end

# staging の目視用の店舗(初回ツアーの前半とスポットライトの目視)。e2e_visual_store は、名前が e2e-visual- の形の無料店舗を 1 件作り、source の
# 店舗の administrator(SuperAdmin でなく、メール確認済みの利用者)全員を新しい店舗の administrator として所属させる。利用者は作らず、
# パスワード・メールアドレスは引数にも出力にも出さない(source の店舗に administrator でログイン済みのブラウザーが、新しい店舗のツアーを
# そのまま開ける)。店舗の初期状態は無料登録で確認と有効化まで済んだ店舗と同じ(FreeRegistration#prepare_visual!)で、規約同意の記録は
# 残さない(本人の同意ではないため)。ツアー(growth guide)の状態は利用者の側にあり、何も書かない(新しい店舗の既定のまま)。
# 作った店舗には同じ transaction で作成票(internal_attributes の toybaco_e2e_visual。source の id と作成時刻)を書き、store と purge は
# 作成票のある店舗だけを扱う(名前だけでは e2e_visual_store が作った店舗と、同じ名前を付けた実店舗を区別できない)。
# e2e_visual_purge は、名前が完全に一致する作成票のある店舗(ちょうど 1 件)を消す。利用者は消さない(複製した利用者は実在の利用者で、
# メールアドレスの形では区別しない)。店舗名の形は E2eConsent の prefix・run ごとの店舗名の形と別で、e2e_purge_accounts の一致には
# 入らない。store と purge は前方一致でなく名前の完全一致で店舗を引く。環境の判定は E2eConsent と同じ(staging 以外は引数を読む前に
# abort。ops-rake workflow も e2e_ で始まるタスクを staging 以外で拒否する二重の fail-closed)。進めないときは TOYBACO_E2E_VISUAL の
# 1 行(result・店舗の id・reason)で abort する(非 0 で終わり、監査行は failed)。同じ名前の作成票のある店舗があれば、何も書かずに
# skipped(already_exists)で正常に終わる。同じ名前の店舗に作成票が無ければ name_taken で abort する(実店舗の名前を目視用に使わない)。
# 監査行(started / ok|failed)は上の RakeAudit が書く。rake は Rails の初期化前にこのファイルを読むため、モデルとサービスは実行時に参照する。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    module E2eVisual
      # 目視用の店舗名の厳格な形。E2eConsent の PREFIX_FORMAT(e2e-consent-)・RUN_NAME_FORMAT とは重ならない。
      NAME_FORMAT = /\Ae2e-visual-[a-z0-9-]{1,40}\z/
      SOURCE_FORMAT = /\A[1-9]\d{0,9}\z/
      NAME_ERROR = 'name は e2e-visual- に続けて英小文字・数字・- を 1〜40 字で指定してください。'
      # source にしない店舗名(E2E の店舗。所属を複製すると E2E の利用者が E2E の店舗の外に所属し、E2E の後片付けが止まる)。
      E2E_NAME_PREFIX = 'e2e-'
      # 作成票の鍵(internal_attributes)。custom_attributes は管理者が API で書き換えられるため使わない。
      MARKER_KEY = 'toybaco_e2e_visual'
      # store と purge が transaction の中で最初に取る advisory lock(同じ文字列で、互いと同じ rake の同時実行を直列にする)。
      LOCK_SQL = "SELECT pg_advisory_xact_lock(hashtext('toybaco_e2e_visual_store'))"
      NONE = '-'

      module_function

      def staging!(task)
        E2eConsent.staging!(task)
      end

      # toybaco:e2e_visual_store[name,source_account_id]。作成は 1 つの transaction(店舗・所属・契約・無料登録の段階)で行い、その間に
      # 積まれる job は commit の後に送る(E2eConsent::WriteGuard.jobs_after_commit)。
      def store(args)
        staging!('e2e_visual_store')
        name, source_id = store_arguments!(args)
        E2eConsent::WriteGuard.jobs_after_commit { ActiveRecord::Base.transaction { create!(name, source_id) } }
      end

      # 検査と代入を同じ判定にする(通すのは形に合う文字列 2 つだけで、Symbol・Integer・余分な引数は通さない)。入力の値は出さない。
      def store_arguments!(args)
        name = args[:name]
        source = args[:source_account_id]
        abort NAME_ERROR unless name.is_a?(String) && name.match?(NAME_FORMAT)
        abort 'source_account_id は 1 以上の整数で指定してください。' unless source.is_a?(String) && source.match?(SOURCE_FORMAT)
        abort '引数は name と source_account_id の 2 つだけを指定してください。' unless args.extras.empty?

        [name, Integer(source, 10)]
      end

      # transaction の中で呼ぶ。store と purge の同時実行を transaction の終わりまで直列にしてから(LOCK_SQL)、同じ名前の店舗を確かめる
      # (同時に 2 件作らない)。同じ名前の店舗が 2 件以上なら abort する。1 件なら、作成票があれば何も書かずに skipped、無ければ name_taken で
      # abort する。
      def create!(name, source_id)
        ActiveRecord::Base.connection.execute(LOCK_SQL)
        existing = named(name)
        refuse!(nil, 'multiple_accounts') if existing.size > 1
        refuse!(existing.first.id, 'name_taken') if existing.any? && !marker?(existing.first)
        return line('skipped', existing.first.id, 'already_exists') if existing.any?

        build!(name, Account.find_by(id: source_id))
      end

      # 店舗を作り、複製する administrator を所属させてから、無料登録で確認と有効化まで済んだ店舗と同じ初期状態にし、作成票を書く。契約者
      # (無料登録の owner)は、複製した administrator のうち id が最小の利用者。無料登録がカタログで使えない環境では作らない。
      def build!(name, source)
        administrators = administrators!(source)
        refuse!(nil, 'free_unavailable') unless Toybaco::Growth::FreeRegistration.enabled?
        account = Account.create!(name: name, locale: 'ja')
        administrators.each { |user| AccountUser.create!(account: account, user: user, role: :administrator) }
        Toybaco::Growth::FreeRegistration.new.prepare_visual!(account, owner: administrators.first)
        mark!(account, source)
        line('created', account.id, NONE, 'source' => source.id, 'administrators' => administrators.size)
      end

      # 作成票(source の id と、UTC の ISO 8601 の作成時刻)。契約・無料登録の段階と同じく internal_attributes 全体に merge して書く。
      def mark!(account, source)
        marker = { 'source_account_id' => source.id, 'created_at' => Time.now.utc.iso8601 }
        account.update!(internal_attributes: Toybaco::Entitlements.attributes(account).merge(MARKER_KEY => marker))
      end

      # e2e_visual_store が作った店舗か(作成票が Hash で、source の id が Integer)。
      def marker?(account)
        marker = Toybaco::Entitlements.attributes(account)[MARKER_KEY]
        marker.is_a?(Hash) && marker['source_account_id'].is_a?(Integer)
      end

      # source の店舗の administrator のうち、SuperAdmin(type あり)でなくメール確認済みの利用者(id の順)。source が無い・停止中・E2E の
      # 店舗・対象の利用者が 0 人なら、理由を 1 行で出して abort する。
      def administrators!(source)
        refuse!(nil, 'source_missing') unless source
        refuse!(source.id, 'source_inactive') unless source.active?
        refuse!(source.id, 'source_is_e2e') if source.name.to_s.start_with?(E2E_NAME_PREFIX)
        ids = AccountUser.where(account_id: source.id, role: :administrator).select(:user_id)
        users = User.where(id: ids).order(:id).select { |user| user.type.blank? && user.confirmed? }
        refuse!(source.id, 'source_no_administrator') if users.empty?

        users
      end

      # toybaco:e2e_visual_purge[name]。名前が完全に一致する店舗が 2 件以上か、1 件で作成票が無ければ、transaction を開く前に何も消さずに
      # abort する。0 件なら何も消さずに 0 件を出す。
      def purge(args)
        staging!('e2e_visual_purge')
        name = E2eConsent.argument!(args, :name, NAME_FORMAT, NAME_ERROR)
        stores = named(name)
        abort "name=#{name} に一致する店舗が #{stores.size} 件あるため削除しません。" if stores.size > 1
        abort "name=#{name} の店舗 account=#{stores.first.id} は e2e_visual_store が作った店舗でない(作成票なし)ため削除しません。" if stores.any? && !marker?(stores.first)

        Removal.run(name, stores)
      end

      # 名前が name と完全に一致する店舗(id の順)。DB の一致に加えて Ruby でも == を確かめる(前方一致では引かない)。
      def named(name)
        Account.where(name: name).order(:id).select { |account| account.name == name }
      end

      def line(result, account_id, reason, fields = {})
        ["TOYBACO_E2E_VISUAL result=#{result} account=#{account_id || NONE}", *fields.map { |key, value| "#{key}=#{value}" },
         "reason=#{reason}"].join(' ')
      end

      # 進めないときの 1 行で abort する(transaction の中なら rollback する)。
      def refuse!(account_id, reason)
        abort line('refused', account_id, reason)
      end

      # 目視用の店舗の削除。E2eConsent::Purge の部品(店舗が残っているうちに消す子、DeleteObjectJob の処理、体験と自動応答の記録、読み直し)と
      # WriteGuard(行ロックした店舗の名前の確かめ直し、job の commit 後送り)をそのまま使う。利用者は消さない(複製した利用者は実在の
      # 利用者で、メールアドレスの形では区別しない。E2E 用の形のメールアドレスの利用者も消さない)。DeleteObjectJob に渡すのは店舗だけで、
      # 所属は店舗と一緒に消える。Purge.delete! は使わない(利用者・契約者を消す手順を含むため)。出力の users は常に 0、skipped_users は
      # 消す前の店舗の所属の利用者の数(同じ利用者は 1 回)。
      module Removal
        module_function

        def run(name, stores)
          deleted, members = E2eConsent::WriteGuard.jobs_after_commit { ActiveRecord::Base.transaction { delete!(name, stores) } }
          "TOYBACO_E2E_VISUAL_PURGE name=#{name} accounts=#{deleted.size} users=0 skipped_users=#{members.size}"
        end

        # transaction の中で呼ぶ。最初に store と同じ advisory lock(LOCK_SQL)を取り、store や別の purge と重ならないようにする。ロックを
        # 待つ間に先の purge が消し終えた店舗は外す(transaction の前に選んだ店舗のまま行ロックで読み直すと ActiveRecord::RecordNotFound に
        # なり、正常の行で終わらない。外した店舗は accounts に数えない)。続けて店舗を行ロックして名前(完全一致と厳格な形)と作成票を
        # 確かめ直し、所属の利用者を控えてから、子・店舗・体験と自動応答の記録の順に消す。読み直して残っていれば abort(SystemExit)で
        # rollback して何も消さない。消した店舗と、消す前の所属の利用者の id を返す。
        def delete!(name, stores)
          purge = E2eConsent::Purge
          ActiveRecord::Base.connection.execute(LOCK_SQL)
          stores = stores.select { |store| Account.exists?(store.id) }
          E2eConsent::WriteGuard.relock!(name, stores, '削除', name_format: NAME_FORMAT) { |store| store.name == name && E2eVisual.marker?(store) }
          ids = stores.map(&:id)
          members = AccountUser.where(account_id: ids).distinct.pluck(:user_id)
          purge.children!(ids)
          stores.each { |store| DeleteObjectJob.new.perform(store) }
          E2eConsent::Purge::GrowthRecords.delete!(ids)
          return [stores, members] unless purge.remaining?(ids, [])

          abort "name=#{name} の削除を読み直すと店舗・所属・bot・体験と自動応答の記録が残っているため、削除を取り消します。"
        end
      end
    end
  end
end

namespace :toybaco do
  desc 'staging 専用: 目視用の無料店舗(名前は e2e-visual-…)を 1 件作り、source の店舗の確認済み administrator を administrator として所属させる' \
       '(rake "toybaco:e2e_visual_store[e2e-visual-<name>,source_account_id]")'
  task :e2e_visual_store, %i[name source_account_id] => :environment do |_t, args|
    puts Toybaco::Ops::E2eVisual.store(args)
  end

  desc 'staging 専用: 名前が完全に一致する目視用の店舗(1 件)と所属を削除する。複製した利用者は消さない' \
       '(rake "toybaco:e2e_visual_purge[e2e-visual-<name>]")'
  task :e2e_visual_purge, %i[name] => :environment do |_t, args|
    puts Toybaco::Ops::E2eVisual.purge(args)
  end
end

# 確認待ち(attention)の行を、運営が理由を付けて閉じる・購読照合を始め直す(2026-10-20、時間経過で固着する課金の確認待ち)。
# - toybaco:billing_attention_close[id,理由] は課金通知の受付(BillingEvent)、toybaco:sync_attention_close[id,理由] は購読照合の要求
#   (SubscriptionSyncRequest)、toybaco:opening_attention_close[id,理由] は開通後の初期設定(OpeningRequest の onboarding_state)、
#   toybaco:renewal_attention_close[id,理由] は更新請求の処理(GrowthRenewalDispatch)の確認待ちを閉じる。
#   toybaco:sync_attention_retry[id,理由] は購読照合の要求を確認待ちから始め直す(新しい通知が届いた時と同じ re-arm で revision を
#   1 つ進め、照合の job を積む。積めなければ毎分の sweep が積み直す)。要求に保存した店舗が、今その購読を持つ唯一の店舗でなければ
#   止め(account-moved)、理由 rebind の時だけ要求の店舗を外して結び付け直す(今の店舗が 2 件以上なら rebind も止める)。
# - 引数は行の ID(1 以上の整数)と理由語(CLOSE_REASONS / RETRY_REASONS の 1 つ)だけ。メールアドレスや自由文は取らない。
# - 行の書き換えと監査行(toybaco_operator_actions。実行者は TOYBACO_OPS_ACTOR、action は attention.<種類>.<close|retry>.<理由>、
#   対象はその行、params は id・理由・前の状態と結果の digest)を同じ transaction で確定させる。監査行を書けなければ行も変えない。
#   開始と終了(started / ok|failed)の監査行は先頭の RakeAudit が別の DB セッションで書く。
# - 閉じた後の状態: 受付と購読照合は completed(result operator_closed。受付は recovery_log にも理由と実行者を残す)。初期設定は
#   onboarding_state ready(CHECK が許す値は pending / ready / attention だけ)。更新請求の処理は idle(phase はそのまま、result
#   operator_closed)。どれも sweep は拾わず、毎分の確認待ちのログと日次ダイジェストの件数から外れる。閉じても Stripe や店舗の契約は
#   変えない(対応は先に運営が済ませる)。
# - 書かずに止める(abort。監査行は failed): 行が無い・確認待ちでない・購読照合で Free 復帰の停止を sweep が再試行している
#   (SubscriptionReconciliation.suspension_due?。閉じると停止の再試行が止まる。始め直しは止めない)・更新請求の処理の phase が
#   grace_ready(idle にすると猶予の期日に sweep が再実行する)か、店舗が今も持つ購読の未完の phase(received / due_waiting /
#   provider_closed。idle にすると RenewalDispatchSyncGuard#pending? が受け入れる phase にならず、同じ請求の更新を再開できない)か、
#   同じ operation に未完の coordinator(N2)がある。
# - 出力は TOYBACO_ATTENTION_OPS の 1 行(kind・id・操作・理由・前後の状態・前の結果)。値は toybaco:renewal_attention と同じ整形
#   (RenewalFormat.token)にし、ops-rake の Step Summary のマスクに当たらないようにする。止める理由の語も - でつなぐ。
# rake は Rails の初期化前にこのファイルを読むため、モデル・Audit・SubscriptionReconciliation・RenewalFormat は実行時に参照する。
module Toybaco::Ops::AttentionOps
  ID_FORMAT = /\A[1-9]\d{0,9}\z/
  PREFIX = 'TOYBACO_ATTENTION_OPS'
  # 閉じる理由。foreign: 他製品(Stripe 共用)の通知、handled: 運営が手作業で対応した、refunded: 返金で対応した、
  # duplicate: 同じ事象の重複、test: 試験のデータ。
  CLOSE_REASONS = %w[foreign handled refunded duplicate test].freeze
  # 購読照合を始め直す理由。fixed: 原因(契約・店舗の設定)を直した、transient: 一時的な障害だった、rebind: 購読を持つ店舗を
  # 直した(重複の結び付けを 1 店舗に直したなど)ので、要求の店舗を外して今の唯一の店舗に結び付け直す。
  RETRY_REASONS = %w[fixed transient rebind].freeze
  CLOSED = 'operator_closed'
  # 更新請求の処理が終わっていない phase(終わると idle で grace_ready / paid_ready / free_completed になる)。
  UNFINISHED_PHASES = %w[received due_waiting provider_closed].freeze

  module_function

  def close_billing(args)
    perform({ kind: 'billing-event', verb: 'close', model: Toybaco::BillingEvent }, args) do |row, context|
      now = context.fetch(:now)
      entry = { 'action' => 'operator_close', 'reason' => context.fetch(:reason), 'actor' => context.fetch(:actor),
                'closed_at' => now.iso8601, 'previous_result' => row.result, 'previous_attempts' => row.attempts }
      { state: 'completed', result: CLOSED, completed_at: now, lease_token: nil, lease_expires_at: nil, recovery_log: row.recovery_log + [entry] }
    end.last
  end

  def close_sync(args)
    perform({ kind: 'sync-request', verb: 'close', model: Toybaco::SubscriptionSyncRequest }, args) do |row, context|
      refuse!('sync-request', row.id, 'suspension-due') if Toybaco::SubscriptionReconciliation.suspension_due?(row)

      { state: 'completed', result: CLOSED, completed_at: context.fetch(:now) }
    end.last
  end

  def close_opening(args)
    target = { kind: 'opening-request', verb: 'close', model: Toybaco::OpeningRequest, state: :onboarding_state }
    perform(target, args) { { onboarding_state: 'ready' } }.last
  end

  def close_renewal(args)
    perform({ kind: 'renewal-dispatch', verb: 'close', model: Toybaco::GrowthRenewalDispatch }, args) do |row|
      refuse!('renewal-dispatch', row.id, 'grace-ready') if row.phase == 'grace_ready'
      refuse!('renewal-dispatch', row.id, 'current-unfinished') if current_unfinished?(row)
      coordinators = Toybaco::GrowthRenewalCoordinator.where(renewal_operation_id: row.renewal_operation_id).where.not(phase: 'free_completed')
      refuse!('renewal-dispatch', row.id, 'coordinator-pending') if coordinators.exists?

      { state: 'idle', result: CLOSED, lease_token: nil, lease_expires_at: nil }
    end.last
  end

  # 店舗が今も持つ購読(購読 ID の完全一致)の、終わっていない更新請求の処理。
  def current_unfinished?(row)
    subscription = Toybaco::RenewalOperation.find(row.renewal_operation_id).subscription_id
    UNFINISHED_PHASES.include?(row.phase) && Toybaco::SubscriptionReconciliation.accounts_for(subscription).exists?
  end

  # 購読照合を始め直す。commit の後に積む(Dispatch.enqueue は自分の行ロックで予約し、積めなければ毎分の sweep が積み直す)。
  def retry_sync(args)
    target = { kind: 'sync-request', verb: 'retry', model: Toybaco::SubscriptionSyncRequest, reasons: RETRY_REASONS }
    row, line = perform(target, args) do |request, context|
      Toybaco::SubscriptionReconciliation.rearm_values(context.fetch(:now)).merge(requested_revision: request.requested_revision + 1)
                                         .merge(rebind_values(request, context))
    end
    queued = Toybaco::SubscriptionReconciliation::Dispatch.enqueue(row, now: Time.now.utc)
    "#{line} revision=#{row.requested_revision} enqueued=#{!queued.nil?}"
  end

  # 要求に保存した店舗と、今その購読を持つ店舗(購読 ID の完全一致)を行ロックの中で照合する。保存した店舗が今の唯一の店舗でなければ
  # (店舗が移った・0 件・2 件以上)、そのまま始め直しても照合は今の店舗を照合しない(別の店舗が持てば account_moved の確認待ちに
  # 戻り、どの店舗も持たなければ superseded で確認待ちの一覧から消える)ので止める(account-moved)。rebind の時だけ要求の店舗を外し、照合の bind_account の一意検査に任せる。今の店舗が 2 件以上なら
  # rebind も止める(bind_account が決められない。先に重複を直す)。前の店舗と照合の時点の店舗は、監査行の params と出力に残す。
  def rebind_values(request, context)
    owners = Toybaco::SubscriptionReconciliation.accounts_for(request.subscription_id).limit(2).pluck(:id)
    seen = [request.account_id || 'none', { 0 => 'none', 1 => owners.first }.fetch(owners.size, 'multiple')]
    context[:audit] = { 'previous_account_id' => seen.first, 'owner' => seen.last }
    context[:suffix] = " previous_account=#{seen.first} owner=#{seen.last}"
    if context.fetch(:reason) == 'rebind'
      refuse!('sync-request', request.id, 'multiple-owners') if owners.size > 1
      return { account_id: nil }
    end
    refuse!('sync-request', request.id, 'account-moved') if request.account_id && owners != [request.account_id]
    {}
  end

  # 行を行ロックで読み直し、確認待ちであることを確かめてから、ブロックが返す値で書き換え、同じ transaction で監査行を書く。
  # target は種類(kind)・操作(verb)・モデル・状態の列(state。既定は state)・理由語の名簿(reasons。既定は CLOSE_REASONS)。
  # 書き換えた行と出力の 1 行を返す。進めないときは理由の 1 行で abort する(transaction の中なので何も書かれない)。
  def perform(target, args)
    kind = target.fetch(:kind)
    state = target.fetch(:state, :state)
    id, reason = arguments!(args, target.fetch(:reasons, CLOSE_REASONS))
    context = { kind: kind, verb: target.fetch(:verb), reason: reason, now: Time.now.utc,
                actor: audit_env('TOYBACO_OPS_ACTOR', Toybaco::Ops::RakeAudit::ACTOR_FORMAT, 'unknown') }
    ActiveRecord::Base.transaction do
      row = target.fetch(:model).lock.find_by(id: id)
      refuse!(kind, id, 'not-found') unless row
      before = { 'state' => row[state], 'result' => row.has_attribute?(:result) ? row.result : nil }
      refuse!(kind, id, 'not-attention') unless before.fetch('state') == 'attention'

      row.update!(yield(row, context))
      audit!(row, context, before)
      [row, line(context, row.id, row[state], before)]
    end
  end

  # 検査と代入を同じ判定にする(通すのは 1 以上の整数の文字列と、名簿の理由語の 2 つだけ。Integer や余分な引数は通さない)。
  def arguments!(args, reasons)
    raw = args[:id]
    reason = args[:reason]
    abort "#{PREFIX}_ABORT reason=id-invalid" unless raw.is_a?(String) && raw.match?(ID_FORMAT)
    abort "#{PREFIX}_ABORT reason=reason-invalid allowed=#{reasons.join('|')}" unless reason.is_a?(String) && reasons.include?(reason)
    abort "#{PREFIX}_ABORT reason=extra-arguments" unless args.extras.empty?

    [Integer(raw, 10), reason]
  end

  # 理由は action に入れて読めるようにし、params(id・理由・前の状態と結果、始め直しは前の店舗と照合の時点の店舗も)は digest だけを残す。
  def audit!(row, context, before)
    action = "attention.#{context.fetch(:kind).tr('-', '_')}.#{context.fetch(:verb)}.#{context.fetch(:reason)}"
    Toybaco::Ops::Audit.record!(actor_kind: 'rake', actor_id: context.fetch(:actor), action: action, target: row,
                                params: { 'id' => row.id, 'reason' => context.fetch(:reason) }.merge(before, context.fetch(:audit, {})), result: 'ok',
                                source: audit_env('TOYBACO_OPS_SOURCE', Toybaco::Ops::RakeAudit::SOURCE_FORMAT, 'rake:unspecified'))
  end

  # RakeAudit と同じ値(未設定・空なら既定値)。形の合わない値は RakeAudit が実行の前に止めるが、ここでも監査行に書かない。
  def audit_env(name, format, fallback)
    value = ENV.fetch(name, nil)
    value.present? && value.match?(format) ? value : fallback
  end

  def line(context, id, state, before)
    format = Toybaco::Ops::RenewalFormat
    "#{PREFIX} kind=#{context.fetch(:kind)} id=#{id} action=#{context.fetch(:verb)} reason=#{context.fetch(:reason)} " \
      "state=#{format.token(state)} previous_state=#{format.token(before.fetch('state'))} " \
      "previous_result=#{format.token(before.fetch('result'))}#{context[:suffix]}"
  end

  def refuse!(kind, id, reason) = abort("#{PREFIX} kind=#{kind} id=#{id} result=refused reason=#{reason}")
end

namespace :toybaco do
  desc '課金通知の受付の確認待ちを、理由を付けて閉じる(rake "toybaco:billing_attention_close[id,foreign|handled|refunded|duplicate|test]")'
  task :billing_attention_close, %i[id reason] => :environment do |_t, args|
    puts Toybaco::Ops::AttentionOps.close_billing(args)
  end

  desc '購読照合の確認待ちを、理由を付けて閉じる(rake "toybaco:sync_attention_close[id,foreign|handled|refunded|duplicate|test]")'
  task :sync_attention_close, %i[id reason] => :environment do |_t, args|
    puts Toybaco::Ops::AttentionOps.close_sync(args)
  end

  desc '購読照合を確認待ちから始め直す(rake "toybaco:sync_attention_retry[id,fixed|transient|rebind]"。rebind は要求の店舗を外して結び付け直す)'
  task :sync_attention_retry, %i[id reason] => :environment do |_t, args|
    puts Toybaco::Ops::AttentionOps.retry_sync(args)
  end

  desc '開通後の初期設定の確認待ちを、理由を付けて閉じる(rake "toybaco:opening_attention_close[id,foreign|handled|refunded|duplicate|test]")'
  task :opening_attention_close, %i[id reason] => :environment do |_t, args|
    puts Toybaco::Ops::AttentionOps.close_opening(args)
  end

  desc '更新請求の処理の確認待ちを、理由を付けて閉じる(rake "toybaco:renewal_attention_close[id,foreign|handled|refunded|duplicate|test]")'
  task :renewal_attention_close, %i[id reason] => :environment do |_t, args|
    puts Toybaco::Ops::AttentionOps.close_renewal(args)
  end
end
