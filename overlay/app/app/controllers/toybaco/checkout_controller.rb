# frozen_string_literal: true

# LP /signup から来たプランで Stripe Checkout Session を作り、決済ページへ渡す。
# ログイン不要(決済先行の自動開通)。カード情報はトイバコでは扱わない。
class Toybaco::CheckoutController < ActionController::Base # rubocop:disable Rails/ApplicationController
  skip_forgery_protection
  before_action :set_no_cache

  def show
    start_checkout(submitted: false)
  end

  def create
    start_checkout(submitted: true)
  end

  private

  def start_checkout(submitted:)
    return if confirmation_required?(submitted)

    session = Toybaco::Checkout.start!(plan: @plan, cycle: @cycle, version: @terms.fetch('plan_version'),
                                       consent: Toybaco::LegalTerms.consent)
    redirect_to session.fetch('url'), allow_other_host: true, status: :see_other
  rescue Toybaco::PlanCatalog::Invalid => e
    render_error(e.message, :conflict)
  rescue Toybaco::Checkout::InvalidPlan
    render_error('プランが正しくありません。料金ページから選び直してください。', :bad_request)
  rescue Toybaco::Checkout::NonJpyPrice
    render_error('このプランの価格が円建てではないため、決済を中止しました。', :unprocessable_entity)
  rescue Toybaco::Checkout::Unavailable
    render_error('いま決済ページを開けません。しばらくしてからお試しください。', :service_unavailable)
  rescue StandardError => e
    Rails.logger.error("toybaco checkout error: #{e.class}: #{e.message}")
    render_error('決済ページの作成に失敗しました。お手数ですが、お問い合わせフォームからご連絡ください。', :bad_gateway)
  end

  # 確認画面は常に表示する。この確認画面から現在の版で送信し、利用規約等への
  # 同意欄にチェックがある場合だけ決済へ進む(同意なしでは決済を始めない)。
  def confirmation_required?(submitted)
    @plan, @cycle = Toybaco::Checkout.normalize_selection(params[:plan], params[:cycle])
    @terms = Toybaco::Checkout::Catalog.sale(@plan, @cycle)
    return render_confirm(:ok) unless submitted && same_site_submission? && params[:version].to_s == @terms.fetch('plan_version')
    return render_confirm(:unprocessable_entity, consent_missing: true) unless params[:accept_terms] == '1'

    false
  end

  def same_site_submission?
    origin = request.headers['Origin']
    [nil, '', 'same-origin'].include?(request.headers['Sec-Fetch-Site']) && (origin.blank? || origin == request.base_url)
  end

  def render_confirm(status, consent_missing: false)
    @consent_missing = consent_missing
    render 'toybaco/checkout/confirm', layout: false, status: status
    true
  end

  def render_error(message, status)
    @message = message
    render 'toybaco/checkout/error', layout: false, status: status
  end

  def set_no_cache
    response.headers['Cache-Control'] = 'no-store'
  end
end
