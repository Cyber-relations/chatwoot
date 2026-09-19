# frozen_string_literal: true

require_relative '../../../lib/toybaco/connections/handoff/issue'
require_relative '../../../lib/toybaco/connections/handoff/presentation'

class Toybaco::ConnectionHandoffRequestsController < ActionController::Base # rubocop:disable Rails/ApplicationController
  Handoff = Toybaco::Connections::Handoff
  skip_forgery_protection
  before_action :load_owner
  before_action :same_origin_json, except: :show
  rescue_from Handoff::Forbidden, with: :forbidden
  rescue_from Handoff::Invalid, ActionController::ParameterMissing, with: :invalid
  rescue_from Handoff::Limited, with: :limited
  rescue_from Handoff::Unavailable, with: :unavailable
  rescue_from ActiveSupport::MessageEncryptor::InvalidMessage, with: :forbidden

  def show
    record = selected
    render json: Handoff::Presentation.owner(record, token: Handoff::Issue.new(@account, @user).link_for(record))
  end

  def create
    input = params.require(:handoff)
    raise Handoff::Invalid unless input.is_a?(ActionController::Parameters) &&
                                  (input.keys - %w[request_id provider recipient inbox_id]).empty?

    record, token = Handoff::Issue.new(@account, @user).create!(**input.permit(:request_id, :provider, :recipient, :inbox_id).to_h.symbolize_keys)
    render json: Handoff::Presentation.owner(record, token: token), status: :created
  rescue ArgumentError
    invalid
  end

  def revoke
    record = selected
    Handoff::Issue.new(@account, @user).revoke!(record)
    render json: Handoff::Presentation.owner(record.reload)
  end

  private

  def load_owner
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
    @user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
    return head :unauthorized unless @user
    return head :bad_request unless params[:account_id].to_s.match?(/\A[1-9]\d{0,15}\z/)

    @account = @user.account_users.find_by(account_id: params[:account_id])&.account
    raise Handoff::Forbidden unless @account

    Handoff::Access.administrator!(@account, @user)
  end

  def selected
    raise Handoff::Invalid unless params[:id].to_s.match?(Handoff::Access::UUID)

    @account_handoff ||= Toybaco::ConnectionHandoff.find_by!(account_id: @account.id, public_id: params[:id])
  rescue ActiveRecord::RecordNotFound
    raise Handoff::Forbidden
  end

  def same_origin_json
    valid = request.media_type == 'application/json' && request.headers['Origin'] == request.base_url &&
            [nil, '', 'same-origin'].include?(request.headers['Sec-Fetch-Site']) && request.raw_post.bytesize <= 8192
    head :forbidden unless valid
  end

  def forbidden(_error = nil)
    head :forbidden
  end

  def invalid(_error = nil)
    render json: { error: '依頼内容を確認してください。' }, status: :unprocessable_entity
  end

  def limited(_error = nil)
    render json: { error: '新しい依頼は時間をおいてお試しください。' }, status: :too_many_requests
  end

  def unavailable(_error = nil)
    render json: { error: '設定依頼は現在準備中です。' }, status: :service_unavailable
  end
end
