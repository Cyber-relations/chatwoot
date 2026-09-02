# frozen_string_literal: true

# LP /signup から来たプランで Stripe Checkout Session を作り、決済ページへ渡す。
# ログイン不要(決済先行の自動開通)。カード情報はトイバコでは扱わない。
class Toybaco::CheckoutController < ActionController::Base # rubocop:disable Rails/ApplicationController
  skip_forgery_protection
  before_action :set_no_cache

  def show
    start_checkout
  end

  def create
    start_checkout
  end

  private

  def start_checkout
    session = Toybaco::Checkout.start!(plan: params[:plan], cycle: params[:cycle])
    redirect_to session.fetch('url'), allow_other_host: true, status: :see_other
  rescue Toybaco::Checkout::InvalidPlan
    render_error('プランが正しくありません。料金ページから選び直してください。', :bad_request)
  rescue Toybaco::Checkout::NonJpyPrice
    render_error('このプランの価格が円建てではないため、決済を中止しました。', :unprocessable_entity)
  rescue Toybaco::Checkout::Unavailable
    render_error('いま決済ページを開けません。しばらくしてからお試しください。', :service_unavailable)
  rescue StandardError => e
    Rails.logger.error("toybaco checkout error: #{e.class}: #{e.message}")
    render_error('決済ページの作成に失敗しました。右下のチャットからお申し込みください。', :bad_gateway)
  end

  def render_error(message, status)
    @message = message
    render 'toybaco/checkout/error', layout: false, status: status
  end

  def set_no_cache
    response.headers['Cache-Control'] = 'no-store'
  end
end
