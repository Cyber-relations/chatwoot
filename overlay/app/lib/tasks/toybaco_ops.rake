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

# staging の E2E(規約同意の記録の経路の確認)用。3 本とも引数は E2E の店舗名の prefix(e2e-consent- で始まる形)だけで、E2E の利用者の
# メールアドレスも e2e-consent- を含む形に限り、実顧客の店舗・利用者には当たらないようにする。読み取り(legal_consents_by_name)は両環境で使え、
# 書き込み(e2e_confirm_user / e2e_purge_accounts)は staging 専用。環境の判定は ConnectionReleaseOps と同じ Input.staging?
# (TOYBACO_DEPLOYMENT_ENVIRONMENT)で、production と環境が不明なときは引数を読む前に abort する。ops-rake workflow も e2e_ で始まるタスクを
# staging 以外では拒否する(二重の fail-closed)。出力は ID・経路・段階だけで、メールアドレス・氏名は出さない。監査行(started / ok|failed)は
# 上の RakeAudit が書く。rake は Rails の初期化前にこのファイルを読むため、モデルとジョブは実行時に参照する。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    module E2eConsent
      NAME_PREFIX = 'e2e-consent-'
      PREFIX_FORMAT = /\Ae2e-consent-[a-z0-9-]{1,40}\z/
      # 書き込みの 2 本(確認・削除)が扱う店舗名の厳格な形。staging E2E の run ごとの店舗名 e2e-consent-r<run id>-<attempt> だけ。
      # prefix に一致してもこの形でない店舗(例: 実店舗の e2e-consent-registration)が 1 件でもあれば、どちらも何もせずに abort する。
      RUN_NAME_FORMAT = /\Ae2e-consent-r\d{1,20}-\d{1,3}\z/
      # E2E の利用者のメールアドレスの形。受信箱の plus addressing(<local>+e2e-consent-<tag>@<domain>)か、local 部が e2e-consent-<tag>
      # そのものの形だけ。確認と削除で E2E の利用者だけを扱うために使う。登録時のメールアドレスは小文字にそろえて保存されるため、大文字は通さない。
      EMAIL_FORMAT = /\A(?:[a-z0-9][a-z0-9._-]{0,63}\+)?e2e-consent-[a-z0-9-]{1,40}@(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/
      PURGE_LIMIT = 5
      PHASE_FORMAT = /\A[a-z_]{1,32}\z/

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
        argument!(args, :prefix, PREFIX_FORMAT, 'prefix は e2e-consent- に続けて英小文字・数字・- を 1〜40 字で指定してください。')
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
      # (TOYBACO_E2E_PURGE の行の形は変えない)。
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
        # 別の接続が名前や状態を変えていれば、何も書かずに abort する(ロックの後は commit まで変えられない)。
        def relock!(prefix, stores, action)
          stores.sort_by(&:id).each do |store|
            store.reload(lock: true)
            next if store.name.start_with?(prefix) && store.name.match?(RUN_NAME_FORMAT) && (!block_given? || yield(store))

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
        # 消した体験と自動応答の記録の件数の行(TOYBACO_E2E_PURGE_GROWTH)の 2 行。
        def run(prefix, matched)
          stores = matched.first(PURGE_LIMIT)
          found = candidates(stores.map(&:id), matched.map(&:id))
          users, kept, growth = WriteGuard.jobs_after_commit { ActiveRecord::Base.transaction { delete!(prefix, matched, stores, found) } }
          skipped = ((found + kept).map(&:id) - users.map(&:id)).uniq.size
          remaining = matched.size - stores.size
          ["TOYBACO_E2E_PURGE prefix=#{prefix} accounts=#{stores.size} users=#{users.size} skipped_users=#{skipped} remaining=#{remaining}",
           GrowthRecords.line(prefix, growth)]
        end

        # transaction の中で呼ぶ。最初に一致集合の全店舗を行ロックして確かめ直し(バッチの店舗も同じ object が読み直される)、以後の判定と
        # 削除はロックした店舗の id で行う。消した利用者と、消さずに残す契約者と、消した体験と自動応答の記録の件数を返す。契約者は所属から
        # 選んだ候補とは別に、確かめた上で消す集合に入れる(所属が既に無い契約者も残さない)。体験と自動応答の記録は、店舗を消す前に控えた
        # バッチの id(全ての一致が E2E の店舗名の厳格な形で、ロックして確かめ直した店舗)のものだけを、店舗を消した後に消す。
        def delete!(prefix, matched, stores, found)
          WriteGuard.relock!(prefix, matched, '削除')
          ids = stores.map(&:id)
          removable, kept = owners!(stores, ids, matched.map(&:id))
          eligible = (removable + found.select { |user| locked_eligible?(user, ids) }).uniq(&:id)
          children!(ids)
          (eligible + stores).each { |record| DeleteObjectJob.new.perform(record) }
          growth = GrowthRecords.delete!(ids)
          return [eligible, kept, growth] unless remaining?(ids, eligible)

          abort "prefix=#{prefix} の削除を読み直すと店舗・利用者・所属・bot・体験と自動応答の記録が残っているため、削除を取り消します。"
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

  desc 'staging 専用: 名前が prefix で始まる E2E の店舗(id の順に 1 回 5 件まで。残りの件数を出す)と、その店舗だけの利用者と、' \
       'その店舗の体験・自動応答の記録を削除する(rake "toybaco:e2e_purge_accounts[e2e-consent-<run>]")'
  task :e2e_purge_accounts, %i[prefix] => :environment do |_t, args|
    puts Toybaco::Ops::E2eConsent.purge(args)
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

      # 本番の開始処理と回答例の受け口。rake では controller(画面)が読まれないため、ここで読む(読み済みなら何もしない)。
      def require_growth!
        %w[trial_start bot_reply managed_auto_install].each { |name| require Rails.root.join("lib/toybaco/growth/#{name}").to_s }
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
      # 止まった実行は、同じ rake の再実行が切り替えから再開する。
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
        # 体験の受信箱と、再開する設置(無ければ nil)を返す。
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

        def replaceable_contract?(account, pending)
          contract = Toybaco::Entitlements.contract_for(account)
          return false if contract.nil? || Toybaco::Entitlements.attributes(account)['toybaco_subscription_id'].present?

          standard?(contract) || (pending.nil? && contract['plan_id'] == 'free')
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
