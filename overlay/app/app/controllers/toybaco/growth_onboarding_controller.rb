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
    # AI返信の使い方を決めるのは管理者だけ(店舗情報の保存と同じ)。「あとで設定する」(skipped の decide)は案内の記録なので誰でもよい。
    return head :forbidden if preference.key?(:ai_reply_choice) && !@onboarding.administrator?

    attributes = preference.permit(:purpose, :inbox_id, :dismissed, :ai_reply_choice, skipped: [], opened: []).to_h
    raise ArgumentError, 'invalid guide steps' unless step_lists_kept?(preference, attributes) && choice_kept?(preference, attributes)

    render json: @onboarding.update!(attributes)
  rescue ArgumentError, ActionController::ParameterMissing
    render json: { error: '操作を確認してください。' }, status: :unprocessable_entity
  end

  def facts
    return head :forbidden unless @onboarding.administrator?
    return choose_industry if params.key?(:industry)
    return head :unprocessable_entity unless params[:confirmed] == true

    fields = params.require(:fields).permit(*Toybaco::Growth::StoreFacts::LIMITS.keys).to_h
    Toybaco::Growth::StoreFacts.new(@account).save!(fields, user: @user)
    render json: @onboarding.read
  rescue ArgumentError, ActionController::ParameterMissing
    render json: { error: '店舗情報の入力内容を確認してください。' }, status: :unprocessable_entity
  end

  private

  # 業種だけを保存する(パックの id か null)。店舗情報の fields・確認は変えず、業種パックの適用もしない。
  def choose_industry
    industry = params[:industry]
    raise ArgumentError, 'industry only' if params.key?(:fields) || params.key?(:confirmed)
    raise ArgumentError, 'invalid industry' unless industry.nil? || industry.is_a?(String)

    Toybaco::Growth::StoreFacts.new(@account).choose_industry!(industry, user: @user)
    render json: @onboarding.read
  end

  # 段の一覧(skipped・opened)は配列だけを受け付ける。strong parameters が落とした値(配列以外)を、指定なしとして通さない。
  def step_lists_kept?(preference, attributes)
    Toybaco::Growth::Onboarding::STEP_LISTS.all? { |key| preference.key?(key) == attributes.key?(key) }
  end

  # AI返信の使い方は文字列 1 つだけ。配列や連想配列(strong parameters が落とす値)を、指定なしとして通さない。
  def choice_kept?(preference, attributes)
    preference.key?(:ai_reply_choice) == attributes.key?('ai_reply_choice')
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
