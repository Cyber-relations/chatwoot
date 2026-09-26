# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/onboarding'

class Toybaco::GrowthOnboardingController < ActionController::Base # rubocop:disable Rails/ApplicationController
  skip_forgery_protection
  before_action :load_membership
  before_action :require_same_origin_json, except: :show

  def show
    render json: @onboarding.read
  end

  def update
    preference = params.require(:preference)
    attributes = preference.permit(:purpose, :inbox_id, :dismissed, skipped: [], opened: []).to_h
    raise ArgumentError, 'invalid guide steps' unless step_lists_kept?(preference, attributes)

    render json: @onboarding.update!(attributes)
  rescue ArgumentError, ActionController::ParameterMissing
    render json: { error: '操作を確認してください。' }, status: :unprocessable_entity
  end

  def facts
    return head :forbidden unless @onboarding.administrator?
    return head :unprocessable_entity unless params[:confirmed] == true

    fields = params.require(:fields).permit(*Toybaco::Growth::StoreFacts::LIMITS.keys).to_h
    Toybaco::Growth::StoreFacts.new(@account).save!(fields, user: @user)
    render json: @onboarding.read
  rescue ArgumentError, ActionController::ParameterMissing
    render json: { error: '店舗情報の入力内容を確認してください。' }, status: :unprocessable_entity
  end

  private

  # 段の一覧(skipped・opened)は配列だけを受け付ける。strong parameters が落とした値(配列以外)を、指定なしとして通さない。
  def step_lists_kept?(preference, attributes)
    Toybaco::Growth::Onboarding::STEP_LISTS.all? { |key| preference.key?(key) == attributes.key?(key) }
  end

  def load_membership
    response.headers['Cache-Control'] = 'no-store'
    @user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
    return head :unauthorized unless @user
    return head :bad_request unless params[:account_id].to_s.match?(/\A[1-9]\d*\z/)

    @account = @user.account_users.find_by(account_id: params[:account_id])&.account
    return head :forbidden unless @account

    @onboarding = Toybaco::Growth::Onboarding.new(@account, @user)
    head :not_found unless @onboarding.enabled?
  end

  def require_same_origin_json
    allowed_site = [nil, '', 'same-origin'].include?(request.headers['Sec-Fetch-Site'])
    head :forbidden unless request.media_type == 'application/json' && request.headers['Origin'] == request.base_url && allowed_site
  end
end
