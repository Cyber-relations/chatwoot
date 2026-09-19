# frozen_string_literal: true

require_relative '../../../lib/toybaco/support/context'
require_relative '../../../lib/toybaco/support/knowledge'
require_relative '../../../lib/toybaco/support/answer'
require_relative '../../../lib/toybaco/support/diagnostics'

class Toybaco::SupportController < ActionController::Base # rubocop:disable Rails/ApplicationController
  skip_forgery_protection
  before_action :load_context
  before_action :require_same_origin_json, only: :create
  rescue_from Toybaco::Support::Answer::Forbidden, Toybaco::Support::Diagnostics::Forbidden, with: :forbidden
  rescue_from Toybaco::Support::Answer::Unavailable, with: :unavailable
  rescue_from Toybaco::Support::Capacity::Limited, with: :limited
  rescue_from Toybaco::Support::Question::Invalid, with: :invalid
  rescue_from Toybaco::Support::Question::PrivateData, with: :private_data

  def show
    render json: { version: Toybaco::Support::Knowledge::VERSION, account_id: @account.id,
                   articles: Toybaco::Support::Knowledge.articles(@context), status: @context.status,
                   ai_available: GlobalConfigService.load('TOYBACO_SUPPORT_AI_ENABLED', false) == true }
  end

  def diagnostics
    render json: Toybaco::Support::Diagnostics.new(@account, @user).call(params[:article_id])
  end

  def create
    render json: Toybaco::Support::Answer.new(@account, @user).call(params[:support_question])
  end

  private

  def require_same_origin_json
    valid = request.media_type == 'application/json' && request.headers['Origin'] == request.base_url &&
            [nil, '', 'same-origin'].include?(request.headers['Sec-Fetch-Site'])
    head :forbidden unless valid
  end

  def forbidden
    head :forbidden
  end

  def unavailable
    render json: { error: 'AIを利用できません。下の手順から確認できます。' }, status: :service_unavailable
  end

  def limited(error)
    response.headers['Retry-After'] = error.retry_after.to_s
    render json: { error: 'AIの利用が集中しています。手順の検索は続けられます。', retry_after: error.retry_after }, status: :too_many_requests
  end

  def invalid
    render json: { error: '操作についての質問を500文字以内で入力してください。' }, status: :unprocessable_entity
  end

  def private_data
    render json: { error: '個人情報や接続キーを取り除き、操作だけを質問してください。' }, status: :unprocessable_entity
  end

  def load_context
    response.headers['Cache-Control'] = 'no-store'
    return head :not_found unless GlobalConfigService.load('TOYBACO_SUPPORT_ENABLED', false) == true

    @user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
    return head :unauthorized unless @user&.confirmed?
    return head :bad_request unless params[:account_id].to_s.match?(/\A[1-9]\d*\z/)

    load_account
  end

  def load_account
    @account = @user.account_users.find_by(account_id: params[:account_id])&.account
    return head :forbidden unless @account

    @context = Toybaco::Support::Context.new(@account, @user)
    head :forbidden unless @context.member?
  end
end
