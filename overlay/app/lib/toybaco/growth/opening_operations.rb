# frozen_string_literal: true

require_relative '../entitlements'
require_relative '../industry_pack'
require_relative 'opening_notices'

# 新しい開通経路(OPENING_INGRESS)の完了と、確認が必要になった時点を運営の通知先へメールで知らせる。
# 旧経路(bot/provision.py)の「自動開通を開始」「契約処理の開始に失敗」と同じ役割を持つ。
# お客様向けの案内(DB flag GROWTH_NOTICES)には依存しない。秘密・カード情報は載せない。
# 通知の失敗は開通処理を止めない(ログに残し、送信は ActiveJob の再試行に任せる)。
module Toybaco::Growth::OpeningOperations
  ADDRESS_ENV = 'TOYBACO_OPERATIONS_EMAIL'
  EMAIL = /\A[^@\s,]+@[^@\s,]+\.[^@\s,]+\z/
  RESULTS = {
    'payment_mismatch' => '決済の内容を開通の条件と照合できませんでした(割引・金額・メールアドレス・業種・契約版など)',
    'record_missing' => '受付の記録が見つかりませんでした',
    'provider_or_processing_unavailable' => 'Stripe または処理が一時的に利用できず、再試行の上限に達しました',
    'retry_limit' => '再試行の上限または受付の期限(24時間)を過ぎました'
  }.freeze
  SETUP_STATES = {
    'industry' => { 'applied' => '適用済み', 'not_selected' => '業種の指定なし', 'pending' => '未適用' },
    'inbox' => { 'ready' => '作成済み', 'blocked' => '受信の準備が整っていないため未作成', 'pending' => '未作成' }
  }.freeze

  module_function

  # 名簿なしで送るのは production だけ。それ以外(staging、未設定や綴り違いの環境名を含む)と、名簿が渡っている
  # 環境では、テスト用の名簿に含まれる宛先にだけ送る(staging の SES の送信許可と同じ範囲)。
  def recipient(environment = ENV)
    address = environment[ADDRESS_ENV].to_s.strip.downcase
    return unless address.match?(EMAIL)

    roster = environment['TOYBACO_STAGING_FIXTURE_EMAILS']
    return address if roster.nil? && environment['TOYBACO_DEPLOYMENT_ENVIRONMENT'] == 'production'

    address if roster.to_s.split(',').map { |value| value.strip.downcase }.include?(address)
  end

  # 店舗の作成(account_ready)を commit した後に呼ぶ。
  def opened!(request)
    deliver(opened_message(request))
  rescue StandardError => e
    failed_notice(e)
  end

  # 開通の受付(opening_checkout)が attention になった後に呼ぶ。店舗は作られていない。
  def failed!(event, result)
    deliver(failed_message(event, result))
  rescue StandardError => e
    failed_notice(e)
  end

  # 店舗の作成後、初期設定が期限内に終わらず attention になった後に呼ぶ。
  def setup_attention!(request)
    deliver(setup_attention_message(request))
  rescue StandardError => e
    failed_notice(e)
  end

  def opened_message(request)
    store = store_lines(request)
    notices = Toybaco::Growth::OpeningNotices.enabled?
    { subject: "【トイバコ】店舗を開通しました: #{store_name(request)}",
      lines: ['決済を確認し、新しい店舗を作成しました。', '', *store, contract_line(request), industry_line(request.industry),
              "Stripe: #{request.session_id} / #{request.subscription_id}",
              "お客様へのログイン案内: #{notices ? '初期設定のあと自動で送ります' : '送信設定(GROWTH_NOTICES)が無効のため送られません。お客様へ個別にご連絡ください'}",
              '', '業界パック・転送用メール受信箱・ログイン案内の準備は、このあと自動で行います。',
              '24時間以内に終わらない場合は「初期設定が完了しませんでした」を別にお送りします。',
              '状況の確認: rake toybaco:opening_attention'] }
  end

  def failed_message(event, result)
    { subject: '【トイバコ】開通できませんでした(確認が必要)',
      lines: ['決済の通知を受け付けましたが、店舗を作成できませんでした。お客様は支払い済みの可能性があります。', '',
              "Checkout Session: #{event.reference_id}",
              "結果: #{result}(#{RESULTS.fetch(result, '確認が必要です')})",
              "受付記録: BillingEvent #{event.id} / OpeningRequest #{event.opening_request_id || 'なし'} / 試行 #{event.attempts} 回",
              '', 'Stripe で Checkout Session と購読の明細(割引・任意オプションの有無、メールアドレス)を確認し、',
              '手動開通(docs/tenant-onboarding-runbook.md)または返金で対応してください。',
              '未完の一覧: rake toybaco:billing_ingress_attention / rake toybaco:opening_attention'] }
  end

  def setup_attention_message(request)
    notice = Toybaco::OpeningNotice.where(opening_request_id: request.id).order(:id).last
    { subject: "【トイバコ】開通後の初期設定が完了しませんでした: #{store_name(request)}",
      lines: ['店舗は作成済みですが、初期設定が期限内に完了しませんでした。', '', *store_lines(request),
              "業界パック: #{SETUP_STATES['industry'].fetch(request.industry_state, request.industry_state)}",
              "転送用メール受信箱: #{SETUP_STATES['inbox'].fetch(request.inbox_state, request.inbox_state)}",
              "お客様へのログイン案内: #{notice ? notice.state : '未作成'}",
              "初期設定の試行: #{request.onboarding_attempts} 回",
              '', '受信の準備(SES の受信設定)と契約・支払い期間を確認し、必要ならお客様へ個別にご連絡ください。',
              '状況の確認: rake toybaco:opening_attention'] }
  end

  def store_lines(request)
    owner = User.find_by(id: request.owner_id)
    ["店舗名: #{store_name(request)}", "店舗ID: #{request.account_id}", "契約者: #{owner&.email || '確認できません'}"]
  end

  def store_name(request)
    Account.find_by(id: request.account_id)&.name.presence || "店舗ID #{request.account_id}"
  end

  def contract_line(request)
    account = Account.find_by(id: request.account_id)
    contract = account && Toybaco::Entitlements.contract_for(account)
    return 'プラン: 確認できません' unless contract

    cycle = { 'month' => '月払い', 'year' => '年払い' }.fetch(contract['cycle'], contract['cycle'].to_s)
    "プラン: #{contract.fetch('name')}(契約版 #{contract.fetch('plan_version')}・#{cycle})"
  end

  def industry_line(industry)
    return '業種: 指定なし(業界パックは適用しません)' if industry.blank?

    "業種: #{Toybaco::IndustryPack.load_pack(industry)&.dig('label') || industry}"
  end

  def deliver(message)
    to = recipient
    unless to
      Rails.logger.warn('TOYBACO_OPERATIONS_NOTICE_SKIPPED reason=recipient')
      return false
    end

    Toybaco::OperationsMailer.with(to: to, subject: message.fetch(:subject), body: message.fetch(:lines).join("\n")).notice.deliver_later
    true
  end

  def failed_notice(error)
    Rails.logger.error("TOYBACO_OPERATIONS_NOTICE_FAILED class=#{error.class}")
    false
  end
end
