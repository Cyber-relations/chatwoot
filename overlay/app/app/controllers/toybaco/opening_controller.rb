# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/opening_notices'

class Toybaco::OpeningController < ActionController::Base # rubocop:disable Rails/ApplicationController
  skip_forgery_protection
  before_action :load_opening
  before_action :same_origin_json, only: :retry_notice
  rescue_from Toybaco::Growth::OpeningAccess::Invalid, with: :unavailable

  def show
    Toybaco::Growth::OpeningAccess.locked(@opening, actor_id: @user.id) do |_account, _owner|
      notice = Toybaco::OpeningNotice.where(opening_request_id: @opening.id).order(:id).last
      render json: @opening.attributes.slice('onboarding_state', 'industry_state', 'inbox_state').merge(
        'notice' => notice&.attributes&.slice('id', 'state')
      )
    end
  end

  def retry_notice
    notice = Toybaco::Growth::OpeningNotices.retry!(
      @opening, actor_id: @user.id, request_id: params[:request_id], previous_id: params[:previous_id],
                acknowledge_unknown: params[:acknowledge_unknown]
    )
    render json: notice.attributes.slice('id', 'state'), status: :accepted
  end

  private

  def load_opening
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
    @user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
    return head :unauthorized unless @user
    return head :bad_request unless params[:account_id].to_s.match?(/\A[1-9]\d*\z/)

    @opening = Toybaco::OpeningRequest.find_by(account_id: params[:account_id], owner_id: @user.id, state: 'account_ready')
    head :forbidden unless @opening
  end

  def same_origin_json
    valid = request.media_type == 'application/json' && request.headers['Origin'] == request.base_url &&
            [nil, '', 'same-origin'].include?(request.headers['Sec-Fetch-Site'])
    head :forbidden unless valid
  end

  def unavailable(_error)
    render json: { error: '現在の案内状況を確認してください。送信中の案内は再送できません。' }, status: :conflict
  end
end
