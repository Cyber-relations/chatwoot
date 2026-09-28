# frozen_string_literal: true

# 運営操作の監査(S1-1): SuperAdmin の操作を toybaco_operator_actions に残す controller フック。
# config/initializers/toybaco_ops.rb が to_prepare で Accounts / SupportReports を prepend する。
# - DB の中で完結する操作(店舗の更新・報告の状態変更)は、操作(super)と監査行を同じトランザクションで確定させ、
#   監査行が書けなければ操作も残さない(fail-closed)。result は応答が 2xx・3xx なら ok、4xx なら rejected、それ以外は failed。
#   例外(super・監査行の書き込みのどちらでも)は、呼び出し元とは別の DB セッションで failed を 1 行書いてから再送出する。
#   外側に別の prepend(Toybaco::BillingAdminStatus の with_lock など)のトランザクションがあっても failed は残る
#   (super を包む around 型で、prepend の順に依存しない)。commit の後(after_commit など)の例外では、ok の行が
#   別セッションから見える(確定済み)ときは failed を足さずに再送出だけする。
# - DB の外にも作用する操作(店舗の削除は DeleteObjectJob を Redis に登録し、enqueue_after_transaction_commit は
#   load_defaults 7.0 の既定 :never)は、DB をロールバックしてもジョブを取り消せない。started を別セッションで先に
#   確定させ、書けなければ super を呼ばない。終了(ok / rejected / failed)も別セッションで書く。
# - 引数は canonical JSON の SHA-256 だけを残す(店舗名・メールアドレスなどの生値は保存しない)。
# - before_action が応答を返した場合(未ログイン、利用停止の理由の入力不足など)は action に届かないため行を残さない。
module Toybaco::Ops::SuperAdminAudit
  IGNORED_PARAMS = %w[controller action authenticity_token _method commit utf8].freeze

  private

  def toybaco_operator_audit(action, target_class, audit_params, &)
    toybaco_operator_transaction(toybaco_operator_context(action, target_class, audit_params), &)
  end

  def toybaco_operator_audit_started_first(action, target_class, audit_params)
    context = toybaco_operator_context(action, target_class, audit_params)
    Toybaco::Ops::Audit.record_isolated!(**context, result: 'started')
    begin
      value = yield
    rescue Exception # rubocop:disable Lint/RescueException
      Toybaco::Ops::Audit.record_isolated!(**context, result: 'failed')
      raise
    end
    Toybaco::Ops::Audit.record_isolated!(**context, result: toybaco_operator_result)
    value
  end

  def toybaco_operator_context(action, target_class, audit_params)
    { actor_kind: 'super_admin', actor_id: current_super_admin.id.to_s, action: action,
      target: target_class.find_by(id: params[:id]), params: audit_params, source: Toybaco::Ops::Audit.web_source(request) }
  end

  def toybaco_operator_transaction(context)
    recorded = nil
    ActiveRecord::Base.transaction do
      yield.tap { recorded = Toybaco::Ops::Audit.record!(**context, result: toybaco_operator_result) }
    end
  rescue Exception # rubocop:disable Lint/RescueException
    Toybaco::Ops::Audit.record_isolated!(**context, result: 'failed') unless recorded && Toybaco::Ops::Audit.committed?(recorded.id)
    raise
  end

  def toybaco_operator_result
    return 'ok' if response.status.between?(200, 399)
    return 'rejected' if response.status.between?(400, 499)

    'failed'
  end

  def toybaco_operator_params
    params.to_unsafe_h.except(*IGNORED_PARAMS)
  end
end

# SuperAdmin::AccountsController(店舗の更新・削除)。対象は params[:id] の Account(無ければ対象なし)。
module Toybaco::Ops::SuperAdminAudit::Accounts
  include Toybaco::Ops::SuperAdminAudit

  def update
    toybaco_operator_audit('super_admin.account.update', Account, toybaco_operator_params) { super() }
  end

  def destroy
    toybaco_operator_audit_started_first('super_admin.account.destroy', Account, toybaco_operator_params) { super() }
  end
end

# SuperAdmin::SupportReportsController(利用者からの報告の状態変更)。引数は id と state だけを digest にする。
module Toybaco::Ops::SuperAdminAudit::SupportReports
  include Toybaco::Ops::SuperAdminAudit

  def update
    toybaco_operator_audit('super_admin.support_report.update', Toybaco::SupportReport,
                           { 'id' => params[:id], 'state' => params[:state] }) { super() }
  end
end
