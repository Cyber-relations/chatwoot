# frozen_string_literal: true

require 'net/http'

# トイバコ内の「ご契約内容」画面。
# プラン・オプションの表示はトイバコ側のデータだけで行い、カード変更・プラン変更・
# 請求履歴など決済情報に触れる操作だけ、ログイン済み本人に紐づくカスタマーポータルの
# セッションを発行して Stripe の安全な画面に渡す(カード情報はトイバコでは一切保持しない)。
class Toybaco::BillingController < ActionController::Base # rubocop:disable Rails/ApplicationController
  skip_forgery_protection
  before_action :set_no_cache
  before_action :load_user_and_account

  PLAN_INFO = {
    'starter' => { name: 'スターター', price: 9_800, total: 10_780 },
    'standard' => { name: 'スタンダード', price: 29_800, total: 32_780 },
    'business' => { name: 'ビジネス', price: 69_800, total: 76_780 }
  }.freeze

  def show
    attrs = @account.internal_attributes || {}
    @plan_key = attrs['toybaco_plan']
    @plan = PLAN_INFO[@plan_key]
    @posting = attrs.dig('postiz', 'enabled') == true
    @subscription_id = attrs['toybaco_subscription_id'].presence
    @admin = @account_user.administrator?
    @portal_ready = @admin && @subscription_id.present? && ENV['TOYBACO_STRIPE_KEY'].present?
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

  private

  # ポータル発行の事前条件(権限・呼び出し元・設定)。満たさない場合はエラー内容を返す
  def portal_guard_error
    return { error: 'forbidden', status: :forbidden } unless @account_user.administrator?

    # 外部サイトからの form POST でセッションを作らせない(結果 URL は本人にしか出さないが行儀として)
    fetch_site = request.headers['Sec-Fetch-Site']
    return { error: 'forbidden', status: :forbidden } if fetch_site.present? && fetch_site != 'same-origin'

    key_or_sub_missing = ENV.fetch('TOYBACO_STRIPE_KEY', '').blank? ||
                         @account.internal_attributes&.dig('toybaco_subscription_id').blank?
    { error: 'not_available', status: :unprocessable_entity } if key_or_sub_missing
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
