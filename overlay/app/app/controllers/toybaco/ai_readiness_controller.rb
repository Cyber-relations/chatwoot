# frozen_string_literal: true

require_relative '../../../lib/toybaco/ai_readiness'

class Toybaco::AiReadinessController < ActionController::Base # rubocop:disable Rails/ApplicationController
  before_action :load_account
  rescue_from ActiveRecord::ActiveRecordError, with: :unavailable

  def show
    render json: Toybaco::AiReadiness.for_account(@account)
  end

  private

  def load_account
    response.headers['Cache-Control'] = 'no-store'
    id = params[:account_id].to_s
    return head :bad_request unless id.match?(/\A[1-9]\d*\z/)

    user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
    @account = user&.account_users&.find_by(account_id: id)&.account
    head :unauthorized unless @account
  end

  def unavailable
    render json: { 'connection' => 'unknown' }, status: :service_unavailable
  end
end
