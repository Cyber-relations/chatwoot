# frozen_string_literal: true

# 運営日次ダイジェスト(S0-2)。23:00 UTC = 08:00 JST に確認待ちと直近 24 時間の動きを件数だけで集計する。
# 予定時刻は Toybaco::Ops::Digest::SCHEDULED_HOUR_UTC で、直近 24 時間の窓の終わり(anchor)と同じ定数を使う。
# ECS は TZ=Asia/Tokyo(infra/terraform/ecs.tf)で、sidekiq-cron(Fugit)はタイムゾーンの無い cron を
# プロセスの TZ で解釈する('0 23 * * *' は 23:00 JST になる)。UTC を明示して TZ に依存させない。
# lib は Zeitwerk の準備が済んだ after_initialize の中で読む(Toybaco::Ops は lib/toybaco/ops から自動で作られる)。
Rails.application.config.after_initialize do
  require_relative '../../lib/toybaco/ops/digest'

  if defined?(Sidekiq::Cron::Job) && Sidekiq.server?
    Sidekiq::Cron::Job.create(name: 'toybaco_ops_digest', cron: "0 #{Toybaco::Ops::Digest::SCHEDULED_HOUR_UTC} * * * UTC",
                              class: 'Toybaco::OpsDigestJob', active_job: true, queue: 'scheduled_jobs', source: 'toybaco')
  end
end

# 運営操作の監査(S1-1)。SuperAdmin の店舗の更新・削除と、利用者からの報告の状態変更を toybaco_operator_actions に残す。
# フック(lib/toybaco/ops/super_admin_audit.rb)は super を包む around 型で、Toybaco::BillingAdminStatus など
# ほかの prepend と順序に依存せず共存する。rake の toybaco:* は lib/tasks/toybaco_ops.rake が包む。
Rails.application.config.to_prepare do
  {
    SuperAdmin::AccountsController => Toybaco::Ops::SuperAdminAudit::Accounts,
    SuperAdmin::SupportReportsController => Toybaco::Ops::SuperAdminAudit::SupportReports
  }.each do |controller, hook|
    controller.prepend(hook) unless controller < hook
  end
end
