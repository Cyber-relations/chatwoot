# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/purchase_session'
require_relative '../../../lib/toybaco/growth/purchase_fulfillment'
require_relative '../../../lib/toybaco/growth/inbox_retention'

class Toybaco::GrowthPurchasesController < ActionController::Base # rubocop:disable Rails/ApplicationController
  skip_forgery_protection
  before_action :load_membership
  before_action :require_same_origin_json, except: %i[show state]
  rescue_from Toybaco::Checkout::Error,
              Toybaco::PlanCatalog::Invalid, Toybaco::SubscriptionSync::Unresolved, with: :unavailable
  rescue_from Toybaco::Growth::InboxRetention::Busy, Toybaco::Growth::InboxRetention::Invalid, with: :unavailable
  rescue_from Toybaco::Growth::PurchaseIntent::Unavailable, with: :purchase_unavailable

  def show
    ids = %w[light standard pro]
    @plans = Toybaco::PlanCatalog.default.sales.select do |plan|
      ids.include?(plan['plan_id']) && plan['plan_version'] == Toybaco::Growth::PurchaseIntent::VERSION && plan['sellable'] == true
    end
    return render plain: '有料プランは現在準備中です。', status: :not_found if @plans.empty?

    render 'toybaco/growth/purchase', layout: false
  end

  def state
    saved = Toybaco::Growth::PurchaseIntent.saved(@account)
    render json: saved ? saved.slice('state', 'selection') : { state: 'none' }
  end

  def create
    selection = params.require(:selection).permit(:plan_id, :plan_version, :cycle).to_h
    render json: service.start!(selection)
  rescue ActionController::ParameterMissing
    render json: { error: '購入するプランを選んでください。' }, status: :unprocessable_entity
  end

  def cancel
    render json: service.cancel!
  end

  def refresh
    saved = service.refresh!
    if saved['state'] == 'payment_pending'
      session_id = Toybaco::Growth::PurchaseIntent.saved(@account).fetch('session_id')
      Toybaco::Growth::PurchaseFulfillment.new(client: client).complete!(session_id)
      saved = service.refresh!
    end
    render json: saved
  end

  private

  def client
    @client ||= Toybaco::Checkout::Client.new(ENV.fetch('TOYBACO_STRIPE_KEY', ''))
  end

  def service
    Toybaco::Growth::PurchaseSession.new(@account, @user, client: client)
  end

  def load_membership
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
    @user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
    return head :unauthorized unless @user
    return head :bad_request unless params[:account_id].to_s.match?(/\A[1-9]\d*\z/)

    @account = @user.account_users.find_by(account_id: params[:account_id])&.account
    return head :forbidden unless @account

    access = Toybaco::BillingAccess.permissions(@account, @user)
    head :forbidden unless access[:can_manage_billing]
  end

  def require_same_origin_json
    valid = request.media_type == 'application/json' && request.headers['Origin'] == request.base_url &&
            [nil, '', 'same-origin'].include?(request.headers['Sec-Fetch-Site'])
    head :forbidden unless valid
  end

  def unavailable(_error)
    render json: { error: '決済の状況を確認できませんでした。画面を更新して、もう一度お試しください。' }, status: :conflict
  end

  def purchase_unavailable(error)
    render json: { error: error.message }, status: :conflict
  end
end
