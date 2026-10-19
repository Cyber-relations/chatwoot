# frozen_string_literal: true

require Rails.root.join('lib/toybaco/postiz_origin')
require Rails.root.join('lib/toybaco/dashboard_frame_policy')
require Rails.root.join('lib/toybaco/content_security_policy_report_only')

# 最外周で応答headerを確定し、controllerや例外画面の経路差で保護が抜けないようにする。
Rails.application.config.middleware.insert_before 0, Toybaco::DashboardFramePolicy
# CSP 段階 1 の Report-Only は強制の frame policy のさらに外に置き、静的ファイル・静的 404・例外画面・CORS・rate limit の
# 応答にも付ける。強制の CSP(frame-ancestors / frame-src、widget の受信箱ごとの frame-ancestors)は別 header で変えない。
Rails.application.config.middleware.insert_before Toybaco::DashboardFramePolicy, Toybaco::ContentSecurityPolicyReportOnly

require Rails.root.join('lib/toybaco/script_policy')
Rails.application.config.middleware.insert_before Toybaco::ContentSecurityPolicyReportOnly, Toybaco::ScriptPolicy

# Sidekiq Web has its own nonce generator and CSP. Its registered middleware
# runs after that generator, before its real template/native header are built.
require 'sidekiq/web'
Sidekiq::Web.use(Toybaco::ScriptPolicy::SidekiqNonce)
