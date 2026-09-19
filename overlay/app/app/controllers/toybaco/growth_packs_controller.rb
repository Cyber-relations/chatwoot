# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/pack_state'
require_relative '../../../lib/toybaco/growth/pack_session'

class Toybaco::GrowthPacksController < ActionController::Base # rubocop:disable Rails/ApplicationController
  skip_forgery_protection
  before_action :load_user, :validate_ids, :load_owner, :require_growth_account
  before_action :require_same_origin_json, except: %i[show state]
  rescue_from Toybaco::Checkout::Error, Toybaco::PlanCatalog::Invalid, ActiveRecord::ActiveRecordError, with: :unavailable
  rescue_from Toybaco::Growth::PurchaseIntent::Unavailable, with: :purchase_unavailable

  def show
    @state = read_state
    render 'toybaco/growth/packs', layout: false
  end

  def state
    render json: read_state
  end

  def create
    render json: service.start!('request_key' => params[:request_key].to_s)
  end

  def cancel
    service.cancel!
    render json: read_state
  end

  def refresh
    service.refresh!
    render json: read_state
  end

  private

  def read_state
    Toybaco::Growth::PackState.new(@account).read(request_key: params[:request_key].presence)
  end

  def service
    client = Toybaco::Checkout::Client.new(ENV.fetch('TOYBACO_STRIPE_KEY', ''))
    Toybaco::Growth::PackSession.new(@account, @user, request_key: params[:request_key].presence, client: client)
  end

  def load_user
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
    @user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
    head :unauthorized unless @user
  end

  def validate_ids
    return head :bad_request unless params[:account_id].to_s.match?(/\A[1-9]\d*\z/)

    head :bad_request if params[:request_key].present? && !params[:request_key].to_s.match?(Toybaco::Growth::PackIntent::REQUEST_KEY)
  end

  def load_owner
    @account = @user.account_users.find_by(account_id: params[:account_id])&.account
    head :forbidden unless @account && Toybaco::BillingAccess.permissions(@account, @user)[:can_manage_billing]
  end

  def require_growth_account
    terms = Toybaco::Entitlements.for_account(@account)
    head :not_found unless @account.active? && terms&.dig('ai_meter') == Toybaco::GrowthTerms::METER
  end

  def require_same_origin_json
    valid = request.media_type == 'application/json' && request.headers['Origin'] == request.base_url &&
            [nil, '', 'same-origin'].include?(request.headers['Sec-Fetch-Site'])
    head :forbidden unless valid
  end

  def unavailable(_error)
    render json: { error: '決済状況を確認できませんでした。もう一度ご確認ください。' }, status: :conflict
  end

  def purchase_unavailable(error)
    render json: { error: error.message }, status: :conflict
  end
end
