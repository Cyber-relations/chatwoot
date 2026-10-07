# frozen_string_literal: true

# 更新系(renewal dispatch・settlement・coordinator・照合)の運用の読み取り(2026-10-05)。
# toybaco:renewal_status[account_id] は 1 店舗の更新の進みを、toybaco:renewal_attention は確認が要る dispatch の行を店舗ごとに出す。
# どちらも読むだけで、DB へ書かず、Account.transaction を開かず、Stripe を呼ばず、job も積まない(監査行 started / ok|failed は
# toybaco_ops.rake の RakeAudit が別の DB セッションで書く)。出力は 1 行 1 事実の key=value で、CloudWatch で絞り込める。
# 秘密・メールアドレス・顧客名・金額の生値は出さない。購読 ID は末尾 6 字だけを出し、顧客・請求書・イベントの ID は出さない。
# 列挙の値と処理の結果は英数字と _ . : - の 64 字以内のものだけを出して _ を - にし(ops-rake の Step Summary のマスクが
# free_completed などを <id> にするため。toybaco:legal_consents と同じ)、それ以外の形は other と出す。形が合っても、Stripe の
# ID・秘密の接頭辞(cus_ / in_ / sk_ など)か数字だけの値は invalid と出す(_ を - にするとマスクも当たらないため)。
# 時刻は UTC の ISO 8601。行の事実は種類ごとに 50 件、renewal_attention の各行は 200 件までで、超えた分は truncated=<残り件数>。
# 該当なしは none。rake は Rails の初期化前にこのファイルを読むため、モジュールは入れ子で定義し、Rails の定数は実行時に参照する。
# 店舗の属性のキーは、初期化前に読める lib(toybaco.rake も読む)の定数を使う。更新の精算(RenewalSettlement)と更新の案内
# (RenewalReminder)の記録のキーだけは、依存が重いので実行時に読む。renewal_attention は先頭に、更新系に関係する DB flag の
# 現在値を出す(installation_configs を GlobalConfig の cache を経由せずに読む。GlobalConfigService.load は行が無いと ENV から
# 行を作るため使わない)。
require_relative '../toybaco/ops/ops_flag'
require_relative '../toybaco/ops/renewal_overdue'
require_relative '../toybaco/entitlements'
require_relative '../toybaco/growth/paid_period'
require_relative '../toybaco/growth/renewal_grace'
require_relative '../toybaco/growth/renewal_transition'
require_relative '../toybaco/growth/free_return_record'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    # 出力の形。値は token・時刻・購読 ID の 3 種類の整形だけを通す。
    module RenewalFormat
      NONE = 'none'
      AMBIGUOUS = 'ambiguous'
      TOKEN_FORMAT = /\A[A-Za-z0-9_.:-]{1,64}\z/
      # Stripe の ID・秘密の接頭辞か、数字だけ(金額・ID)の値。閉じた列挙でない列(result など)に入っても出さない。
      SECRET_FORMAT = /\A(?:cus|in|evt|sub|ch|pi|pm|price|prod|si|cs|sk|rk|whsec|acct)[_-]|\A\d+\z/i
      SUBSCRIPTION_FORMAT = /\Asub_[A-Za-z0-9]+\z/

      module_function

      def line(prefix, fields)
        [prefix, *fields.map { |key, value| "#{key}=#{value}" }].join(' ')
      end

      def token(value)
        return NONE if value.nil? || value == ''
        return 'other' unless value.is_a?(String) && value.match?(TOKEN_FORMAT)

        value.match?(SECRET_FORMAT) ? 'invalid' : value.tr('_', '-')
      end

      def time(value)
        return NONE if value.nil?
        return value.utc.iso8601 if value.respond_to?(:utc)

        value.is_a?(Integer) && value.positive? ? Time.at(value).utc.iso8601 : 'invalid'
      end

      def masked(subscription)
        return NONE if subscription.nil? || subscription == ''

        subscription.is_a?(String) && subscription.match?(SUBSCRIPTION_FORMAT) ? "...#{subscription[-6..]}" : 'invalid'
      end
    end

    module RenewalReport
      ACCOUNT_ID_FORMAT = /\A[1-9]\d{0,9}\z/
      STATUS = 'TOYBACO_RENEWAL_STATUS'
      ATTENTION = 'TOYBACO_RENEWAL_ATTENTION'
      FLAG = 'TOYBACO_RENEWAL_FLAG'
      # 更新系に関係する DB flag。更新の案内メール(RenewalReminder ほか)は GlobalConfigService.load のこの値が true の時だけ送る。
      # 更新の flag(TOYBACO_RENEWAL_DISPATCH_ENABLED など)は task definition の環境変数で、DB には無い。
      DB_FLAGS = %w[TOYBACO_GROWTH_NOTICES_ENABLED].freeze
      # 出力の上限。行の事実は種類ごと、renewal_attention は dispatch の行の数。集計の行は全件で数える。
      STATUS_ROWS = 50
      ATTENTION_ROWS = 200

      module_function

      # 1 店舗の更新の進み。店舗の属性の事実(契約・支払い済みの期間・更新の失敗・更新の精算・journal・Free 復帰の記録・案内の記録)に
      # 続けて、行の事実(operation・dispatch・coordinator・provider の精算・照合 request・投稿停止)を出す。店舗が無ければ found=false の 1 行。
      def status_lines(account_id, now: Time.now.utc)
        account = Account.find_by(id: account_id)
        return ["#{STATUS} account=#{account_id} found=false"] unless account

        attrs = account.internal_attributes.is_a?(Hash) ? account.internal_attributes : {}
        [*RenewalStoreFacts.lines(account, attrs), *RenewalRowFacts.lines(account, attrs['toybaco_subscription_id'], now)]
          .map { |fields| RenewalFormat.line(STATUS, { 'account' => account.id }.merge(fields)) }
      end

      # 確認が要る dispatch の行: attention と、期日を過ぎても claim されていない猶予(overdue_grace、RenewalOverdue)。先頭に
      # DB flag と件数の集計、続けて店舗ごとの件数と各行(ATTENTION_ROWS 件まで)。店舗は operation に結び付いた店舗、無ければ
      # 購読 ID が一致する 1 店舗。一致が無ければ none、2 店舗以上なら ambiguous で、集計では unresolved に数える。
      def attention_lines(now: Time.now.utc)
        dispatches = Toybaco::GrowthRenewalDispatch
        rows = dispatches.where(state: 'attention').or(RenewalOverdue.overdue_grace(dispatches, now)).order(:id).to_a
        groups = RenewalAttentionRows.grouped(rows)
        [*flag_lines, RenewalFormat.line(ATTENTION, attention_summary(rows, groups)), *RenewalAttentionRows.listed(groups, ATTENTION_ROWS)]
      end

      def attention_summary(rows, groups)
        attention = rows.count { |row| row.state == 'attention' }
        resolved = groups.select { |account, _pairs| account.is_a?(Integer) }
        { 'count' => rows.size, 'accounts' => resolved.size, 'unresolved' => rows.size - resolved.sum { |_account, pairs| pairs.size },
          'attention' => attention, 'overdue_grace' => rows.size - attention }
      end

      # 値は toybaco:ops_flag と同じ表記(boolean はそのまま、行が無ければ unset、文字列の "true" / "false" は引用符付き、
      # それ以外は non_boolean)。行の更新時刻のほかは出さない(更新者は記録に無い)。
      def flag_lines
        DB_FLAGS.map do |key|
          row = InstallationConfig.find_by(name: key)
          RenewalFormat.line(FLAG, 'key' => key, 'value' => Toybaco::Ops::OpsFlag.state(row&.value),
                                   'updated_at' => RenewalFormat.time(row&.updated_at))
        end
      end
    end

    # 店舗の属性から読む事実。
    module RenewalStoreFacts
      extend RenewalFormat

      # 案内の記録の段階(出す順)と、記録が対象にする更新(購読 ID:期首の Unix 時刻。RenewalReminder#eligible? が作る)。
      REMINDER_STAGES = %w[initial expired free_transition].freeze
      REMINDER_RENEWAL = /\A(sub_[A-Za-z0-9]+):([1-9]\d*)\z/

      module_function

      def lines(account, attrs)
        [contract(account, attrs), period(attrs), failure(attrs), settlement(attrs), journal(attrs), free_return(account, attrs),
         *reminder(attrs)]
      end

      def contract(account, attrs)
        fields = { 'kind' => 'contract', 'status' => token(account.status), 'subscription' => masked(attrs['toybaco_subscription_id']) }
        contract = Toybaco::Entitlements.contract_for(account)
        return fields.merge('plan' => RenewalFormat::NONE) unless contract

        fields.merge('plan' => token(contract['plan_id']), 'version' => token(contract['plan_version']), 'cycle' => token(contract['cycle']),
                     'addons' => Array(contract['addons']).size, 'legacy' => contract['legacy'] == true)
      rescue Toybaco::PlanCatalog::Invalid
        fields.merge('plan' => 'invalid')
      end

      def period(attrs)
        coverage = attrs[Toybaco::Growth::PaidPeriod::KEY]
        return { 'kind' => 'paid-period', 'term_start' => RenewalFormat::NONE } unless coverage.is_a?(Hash)

        { 'kind' => 'paid-period', 'term_start' => time(coverage['term_start']), 'term_end' => time(coverage['term_end']),
          'cycle' => token(coverage['cycle']) }
      end

      def failure(attrs)
        record = attrs[Toybaco::Growth::RenewalGrace::FAILURE_KEY]
        return { 'kind' => 'renewal-failure', 'first_failed_at' => RenewalFormat::NONE } unless record.is_a?(Hash)

        { 'kind' => 'renewal-failure', 'subscription' => masked(record['subscription_id']), 'first_failed_at' => time(record['first_failed_at']),
          'grace_ends_at' => time(record['grace_ends_at']) }
      end

      def settlement(attrs)
        require_relative '../toybaco/growth/renewal_settlement'
        receipt = attrs[Toybaco::Growth::RenewalSettlement::KEY]
        return { 'kind' => 'renewal-settlement', 'state' => RenewalFormat::NONE } unless receipt.is_a?(Hash)

        { 'kind' => 'renewal-settlement', 'state' => token(receipt['state']), 'observed_at' => time(receipt['observed_at']) }
      end

      # 更新の journal。binding に cancel があれば期末解約(cancel)、無ければ更新の失敗(failure)。
      def journal(attrs)
        value = attrs[Toybaco::Growth::RenewalTransition::KEY]
        return { 'kind' => 'journal', 'state' => RenewalFormat::NONE } unless value.is_a?(Hash)

        binding = value['binding'].is_a?(Hash) ? value['binding'] : {}
        { 'kind' => 'journal', 'state' => token(value['state']), 'cause' => binding.key?('cancel') ? 'cancel' : 'failure',
          'subscription' => masked(binding['subscription_id']), 'prepared_at' => time(value['prepared_at']),
          'observed_at' => time(value['observed_at']) }
      end

      def free_return(account, attrs)
        pointer = attrs[Toybaco::Growth::FreeReturnRecord::KEY]
        records = Toybaco::GrowthFreeReturn.where(account_id: account.id).count
        return { 'kind' => 'free-return', 'pointer' => RenewalFormat::NONE, 'records' => records } unless pointer.is_a?(Hash)

        { 'kind' => 'free-return', 'pointer' => 'present', 'returned_at' => time(pointer['returned_at']), 'records' => records }
      end

      # 更新の案内の記録(RenewalReminder の initial・expired と RenewalFreeNotice の free_transition)。先頭 1 行に対象の更新・
      # 次の確認の時刻・段階の数、続けて段階を決まった順に 1 行ずつ。token・user_id と未知の段階の中身は出さない(数には含める)。
      def reminder(attrs)
        require_relative '../toybaco/growth/renewal_reminder'
        record = attrs[Toybaco::Growth::RenewalReminder::KEY]
        return [{ 'kind' => 'reminder', 'renewal' => RenewalFormat::NONE }] unless record.is_a?(Hash)

        stages = record['stages'].is_a?(Hash) ? record['stages'] : {}
        subscription, term_start = reminder_renewal(record['renewal'])
        [{ 'kind' => 'reminder', 'renewal' => 'present', 'subscription' => subscription, 'term_start' => term_start,
           'next_check_at' => time(record['next_check_at']), 'stages' => stages.size },
         *REMINDER_STAGES.map { |stage| reminder_stage(stage, stages) }]
      end

      # 対象の更新の購読(末尾 6 字)と期首。形が違えば両方 invalid。
      def reminder_renewal(value)
        match = value.is_a?(String) ? value.match(REMINDER_RENEWAL) : nil
        match ? [masked(match[1]), time(Integer(match[2], 10))] : %w[invalid invalid]
      end

      # 段階が無ければ none、値が Hash でなければ other。
      def reminder_stage(stage, stages)
        fields = { 'kind' => 'reminder', 'stage' => stage.tr('_', '-') }
        return fields.merge('state' => RenewalFormat::NONE, 'attempted_at' => RenewalFormat::NONE) unless stages.key?(stage)

        value = stages[stage]
        return fields.merge('state' => 'other', 'attempted_at' => RenewalFormat::NONE) unless value.is_a?(Hash)

        fields.merge('state' => token(value['state']), 'attempted_at' => time(value['attempted_at']))
      end
    end

    # 行から読む事実。operation・dispatch・照合 request は、店舗に結び付いた行と、店舗の今の購読の行を読む。
    module RenewalRowFacts
      extend RenewalFormat

      module_function

      def lines(account, subscription, now)
        scope = operation_scope(account, subscription)
        [*operations(account, scope), *dispatches(scope, now), *coordinators(account), *provider_settlements(account),
         *requests(account, subscription), posting_stop(account)]
      end

      # 種類ごとに RenewalReport::STATUS_ROWS 件まで(id の順)。超えた分は truncated=<残り件数> の 1 行、無ければ none の 1 行。
      def capped(kind, scope, empty_key)
        limit = RenewalReport::STATUS_ROWS
        rows = scope.order(:id).limit(limit).to_a
        return [{ 'kind' => kind, empty_key => RenewalFormat::NONE }] if rows.empty?

        hidden = rows.size < limit ? 0 : scope.count - limit
        hidden.positive? ? [*yield(rows), { 'kind' => kind, 'truncated' => hidden }] : yield(rows)
      end

      # 店舗に結び付いた operation と、店舗の今の購読の operation(購読が無ければ店舗に結び付いた operation だけ)。
      def operation_scope(account, subscription)
        scope = Toybaco::RenewalOperation.where(account_id: account.id)
        subscription.present? ? scope.or(Toybaco::RenewalOperation.where(subscription_id: subscription)) : scope
      end

      # operation の行(dispatch 行の無い operation も出す)。owner は operation の店舗が同じなら same、未設定なら none、
      # 別の店舗なら other(その店舗の id は出さない)。顧客・請求書の ID、source_hash、first_fact_id は出さない。
      def operations(account, scope)
        capped('operation', scope, 'state') do |rows|
          rows.map do |row|
            { 'kind' => 'operation', 'id' => row.id, 'mode' => token(row.mode), 'subscription' => masked(row.subscription_id),
              'state' => token(row.state), 'result' => token(row.result), 'owner' => owner(account, row.account_id),
              'first_failed_at' => time(row.first_failed_at), 'due_at' => time(row.due_at), 'verified_at' => time(row.verified_at),
              'created_at' => time(row.created_at), 'updated_at' => time(row.updated_at) }
          end
        end
      end

      def owner(account, account_id)
        return RenewalFormat::NONE if account_id.nil?

        account_id == account.id ? 'same' : 'other'
      end

      def dispatches(operation_relation, now)
        by_id = operation_relation.index_by(&:id)
        scope = Toybaco::GrowthRenewalDispatch.where(renewal_operation_id: by_id.keys)
        capped('dispatch', scope, 'state') do |rows|
          overdue = RenewalOverdue.overdue_grace(scope.where(id: rows.map(&:id)), now).pluck(:id)
          rows.map { |row| dispatch(row, by_id.fetch(row.renewal_operation_id), overdue.include?(row.id)) }
        end
      end

      def dispatch(row, operation, overdue)
        { 'kind' => 'dispatch', 'id' => row.id, 'mode' => token(operation.mode), 'subscription' => masked(operation.subscription_id),
          'state' => token(row.state), 'phase' => token(row.phase), 'attempts' => row.attempts, 'due_at' => time(row.due_at),
          'deadline_at' => time(row.deadline_at), 'result' => token(row.result), 'overdue' => overdue, 'updated_at' => time(row.updated_at) }
      end

      def coordinators(account)
        capped('coordinator', Toybaco::GrowthRenewalCoordinator.where(account_id: account.id), 'phase') do |rows|
          rows.map do |row|
            { 'kind' => 'coordinator', 'id' => row.id, 'phase' => token(row.phase), 'due_at' => time(row.due_at),
              'updated_at' => time(row.updated_at) }
          end
        end
      end

      def provider_settlements(account)
        capped('provider-settlement', Toybaco::GrowthRenewalSettlement.where(account_id: account.id), 'phase') do |rows|
          rows.map do |row|
            { 'kind' => 'provider-settlement', 'id' => row.id, 'coordinator' => row.coordinator_id, 'phase' => token(row.phase),
              'updated_at' => time(row.updated_at) }
          end
        end
      end

      def requests(account, subscription)
        scope = Toybaco::SubscriptionSyncRequest.where(account_id: account.id)
        scope = scope.or(Toybaco::SubscriptionSyncRequest.where(subscription_id: subscription)) if subscription.present?
        capped('sync-request', scope, 'state') do |rows|
          rows.map do |row|
            { 'kind' => 'sync-request', 'id' => row.id, 'mode' => token(row.mode), 'state' => token(row.state), 'result' => token(row.result),
              'requested_revision' => row.requested_revision, 'completed_revision' => row.completed_revision, 'deadline_at' => time(row.deadline_at) }
          end
        end
      end

      def posting_stop(account)
        stop = Toybaco::GrowthPostingStop.find_by(account_id: account.id, state: 'pending')
        return { 'kind' => 'posting-stop', 'state' => RenewalFormat::NONE } unless stop

        { 'kind' => 'posting-stop', 'state' => 'pending', 'created_at' => time(stop.created_at) }
      end
    end

    # renewal_attention の店舗ごとの組と行。
    module RenewalAttentionRows
      extend RenewalFormat

      module_function

      # 店舗の決まった組(店舗 id の順)、ambiguous、none の順。
      def grouped(rows)
        operations = Toybaco::RenewalOperation.where(id: rows.map(&:renewal_operation_id)).index_by(&:id)
        order = { RenewalFormat::AMBIGUOUS => 1, RenewalFormat::NONE => 2 }
        rows.map { |row| [row, operations[row.renewal_operation_id]] }
            .group_by { |_row, operation| account_for(operation) }
            .sort_by { |account, _pairs| account.is_a?(Integer) ? [0, account] : [order.fetch(account), 0] }
      end

      # 店舗ごとの件数(全件)と各行。各行は limit 件までで、超えた分は truncated=<残り件数> の 1 行。
      def listed(groups, limit)
        shown = 0
        lines = groups.flat_map do |account, pairs|
          visible = pairs.first([limit - shown, 0].max)
          shown += visible.size
          next [] if visible.empty?

          [line(RenewalReport::ATTENTION, 'account' => account, 'count' => pairs.size),
           *visible.map { |row, operation| line(RenewalReport::ATTENTION, row_fields(account, row, operation)) }]
        end
        hidden = groups.sum { |_account, pairs| pairs.size } - shown
        hidden.positive? ? [*lines, line(RenewalReport::ATTENTION, 'truncated' => hidden)] : lines
      end

      def row_fields(account, row, operation)
        { 'account' => account, 'id' => row.id, 'reason' => row.state == 'attention' ? 'attention' : 'overdue-grace',
          'mode' => token(operation&.mode), 'phase' => token(row.phase), 'result' => token(row.result), 'due_at' => time(row.due_at),
          'updated_at' => time(row.updated_at) }
      end

      def account_for(operation)
        return RenewalFormat::NONE unless operation
        return operation.account_id if operation.account_id

        ids = Account.where("internal_attributes ->> 'toybaco_subscription_id' = ?", operation.subscription_id).order(:id).limit(2).pluck(:id)
        return ids.first if ids.one?

        ids.empty? ? RenewalFormat::NONE : RenewalFormat::AMBIGUOUS
      end
    end
  end
end

namespace :toybaco do
  desc '更新系の進みを店舗ごとに読み取りだけで表示する(rake "toybaco:renewal_status[account_id]"。account_id は 1 以上の整数)'
  task :renewal_status, %i[account_id] => :environment do |_t, args|
    report = Toybaco::Ops::RenewalReport
    raw = args[:account_id]
    # 検査と変換を同じ判定にする(通すのは 1 以上の整数の文字列だけで、Ruby から Integer を渡しても通さない)。入力の値は出さない。
    abort 'account_id は 1 以上の整数で指定してください。' unless raw.is_a?(String) && raw.match?(report::ACCOUNT_ID_FORMAT)
    abort '引数は account_id の 1 つだけを指定してください。' unless args.extras.empty?

    report.status_lines(Integer(raw, 10)).each { |line| puts line }
  end

  desc '確認が要る更新の dispatch(attention と、期日を過ぎても claim されない猶予)を店舗ごとに読み取りだけで表示する'
  task renewal_attention: :environment do
    Toybaco::Ops::RenewalReport.attention_lines.each { |line| puts line }
  end
end
