# frozen_string_literal: true

require_relative '../../../lib/toybaco/agent_seat_limit'

# ライトの担当者人数。設定画面の客面表示と 402 文言の正本は AgentSeatLimit。
class Toybaco::AgentSeatLimitController < ActionController::Base # rubocop:disable Rails/ApplicationController
  skip_forgery_protection
  before_action :set_no_cache
  before_action :load_user_and_account

  def show
    render json: Toybaco::AgentSeatLimit.payload(@account)
  end

  private

  def load_user_and_account
    user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
    return head :unauthorized unless user

    account_id = params[:account_id].to_s
    return head :bad_request unless account_id.match?(/\A\d+\z/)

    @account_user = user.account_users.find_by(account_id: account_id)
    return head :forbidden unless @account_user

    @account = @account_user.account
  end

  def set_no_cache
    response.headers['Cache-Control'] = 'no-store'
  end
end
