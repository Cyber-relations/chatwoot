# frozen_string_literal: true

require 'net/http'
require_relative '../../../lib/toybaco/entitlements'
require_relative '../../../lib/toybaco/checkout'
require_relative '../../../lib/toybaco/billing_subscription'
require_relative '../../../lib/toybaco/checkout/plan_change'

# トイバコ内の「ご契約内容」画面。
# プラン変更は版付きカタログの条件を確認して実行する。カード変更・
# 請求履歴は、ログイン済み本人に紐づくカスタマーポータルの
# セッションを発行して Stripe の安全な画面に渡す(カード情報はトイバコでは一切保持しない)。
# 解約はお支払い方法と混ぜず、ご契約内容から 解約する → 解約する の2クリックで期間末解約する。
class Toybaco::BillingController < ActionController::Base # rubocop:disable Rails/ApplicationController
  skip_forgery_protection
  before_action :set_no_cache
  before_action :load_user_and_account
  before_action :guard_plan_change, only: %i[change_preview change_confirm change_refresh change_cancel]
  rescue_from Toybaco::Checkout::Error, Toybaco::PlanCatalog::Invalid, ActiveRecord::ActiveRecordError, with: :plan_change_unavailable
  rescue_from Toybaco::Checkout::PlanChangeError, with: :plan_change_error

  def show
    attrs = @account.internal_attributes || {}
    @plan_key = attrs['toybaco_plan']
    @posting = attrs.dig('postiz', 'enabled') == true
    @subscription_id = attrs['toybaco_subscription_id'].presence
    @admin = @account_user.administrator?
    @portal_ready = @admin && @subscription_id.present? && ENV['TOYBACO_STRIPE_KEY'].present?
    @contract = Toybaco::Entitlements.contract_for(@account)
    @plan = @contract && { name: @contract.fetch('name') }
    load_actual_billing
    @plan_changes = plan_change_service.state if @portal_ready
    render 'toybaco/billing/show', layout: false
  rescue Toybaco::PlanCatalog::Invalid
    @plan = nil
    @billing = nil
    @billing_error = true
    render 'toybaco/billing/show', layout: false
  end

  def portal
    guard = portal_guard_error
    return render(json: { error: guard[:error] }, status: guard[:status]) if guard

    key = ENV.fetch('TOYBACO_STRIPE_KEY', '')
    sub_id = @account.internal_attributes&.dig('toybaco_subscription_id')
    subscription = stripe_request(:get, "/v1/subscriptions/#{sub_id}", key)
    session = stripe_request(:post, '/v1/billing_portal/sessions', key,
                             'customer' => subscription['customer'],
                             'return_url' => "https://#{request.host}/")
    render json: { url: session['url'] }
  rescue StandardError => e
    Rails.logger.error("toybaco billing portal error: #{e.class}: #{e.message}")
    render json: { error: 'portal_failed' }, status: :bad_gateway
  end

  def cancel
    guard = portal_guard_error
    return render(json: { error: guard[:error] }, status: guard[:status]) if guard

    render json: plan_change_service.cancel_subscription(reservation_token: params[:reservation_token])
  end

  def change_preview
    selection = params.permit(:plan_id, :plan_version, :cycle).to_h
    raise Toybaco::Checkout::PlanChangeError, 'changed' unless selection.keys.sort == %w[cycle plan_id plan_version]

    quote = plan_change_service.preview(selection, user_id: @account_user.user_id)
    token = change_verifier.generate(quote, purpose: 'plan-change', expires_in: 10.minutes)
    render json: { quote: quote.slice('target_name', 'target_amount', 'selection', 'policy', 'amount_due', 'period_end', 'effects'),
                   confirmation_token: token }
  end

  def change_confirm
    quote = change_verifier.verified(params[:confirmation_token].to_s, purpose: 'plan-change')
    raise Toybaco::Checkout::PlanChangeError, 'changed' unless quote

    render json: plan_change_service.commit(quote, user_id: @account_user.user_id)
  end

  def change_refresh
    render json: plan_change_service.refresh
  end

  def change_cancel
    render json: plan_change_service.cancel_reservation(params[:confirmation_token].to_s)
  end

  private

  def plan_change_service
    Toybaco::Checkout::PlanChange.new(account: @account, client: Toybaco::Checkout::Client.new(ENV.fetch('TOYBACO_STRIPE_KEY', '')))
  end

  def change_verifier
    Rails.application.message_verifier('toybaco-plan-change')
  end

  def guard_plan_change
    guard = portal_guard_error
    guard ||= { error: 'forbidden', status: :forbidden } unless request.media_type == 'application/json'
    render(json: { error: guard[:error] }, status: guard[:status]) if guard
  end

  def plan_change_error(error)
    message = Toybaco::Checkout::PlanChange::MESSAGES.fetch(error.message, Toybaco::Checkout::PlanChange::MESSAGES['unavailable'])
    render json: { error: error.message, message: message }, status: :conflict
  end

  def plan_change_unavailable(_error)
    render json: { error: 'unavailable', message: Toybaco::Checkout::PlanChange::MESSAGES['unavailable'] }, status: :service_unavailable
  end

  def load_actual_billing
    return unless @admin && @subscription_id && ENV['TOYBACO_STRIPE_KEY'].present?

    client = Toybaco::Checkout::Client.new(ENV.fetch('TOYBACO_STRIPE_KEY'))
    @billing = Toybaco::BillingSubscription.summarize(client.retrieve_subscription(@subscription_id), expected_id: @subscription_id)
  rescue Toybaco::Checkout::Error, Toybaco::BillingSubscription::Unavailable
    @billing_error = true
  end

  # ポータル発行の事前条件(権限・呼び出し元・設定)。満たさない場合はエラー内容を返す
  def portal_guard_error
    return { error: 'forbidden', status: :forbidden } unless @account_user.administrator?

    return { error: 'forbidden', status: :forbidden } unless same_origin_request?

    key_or_sub_missing = ENV.fetch('TOYBACO_STRIPE_KEY', '').blank? ||
                         @account.internal_attributes&.dig('toybaco_subscription_id').blank?
    { error: 'not_available', status: :unprocessable_entity } if key_or_sub_missing
  end

  def same_origin_request?
    fetch_site = request.headers['Sec-Fetch-Site']
    request.headers['Origin'] == request.base_url && (fetch_site.blank? || fetch_site == 'same-origin')
  end

  def load_user_and_account
    user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
    return head :unauthorized unless user

    account_id = params[:account_id].to_s
    return head :bad_request unless account_id.match?(/\A\d+\z/)

    @account_user = user.account_users.find_by(account_id: account_id)
    return head :forbidden unless @account_user

    @account = @account_user.account
  end

  def stripe_request(method, path, key, params = nil)
    uri = URI("https://api.stripe.com#{path}")
    req = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
    req.basic_auth(key, '')
    req.set_form_data(params) if params
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) do |http|
      http.request(req)
    end
    body = JSON.parse(res.body)
    raise "stripe #{res.code}: #{body.dig('error', 'message')}" unless res.is_a?(Net::HTTPSuccess)

    body
  end

  def set_no_cache
    response.headers['Cache-Control'] = 'no-store'
  end
end
