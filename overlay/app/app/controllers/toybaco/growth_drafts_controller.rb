# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/draft_start'
require_relative '../../../lib/toybaco/growth/draft_state'
require_relative '../../../lib/toybaco/growth/usage_summary'

class Toybaco::GrowthDraftsController < ActionController::Base # rubocop:disable Rails/ApplicationController
  skip_forgery_protection
  before_action :load_conversation
  before_action :require_same_origin_json, except: :show
  rescue_from ArgumentError, Toybaco::Growth::AiLedger::Conflict, with: :invalid_request
  rescue_from Toybaco::Growth::DraftStart::Unavailable, with: :unavailable

  def show
    selected = requests.order(id: :desc).first
    selected = requests.find_by(id: params[:request_id]) if params[:request_id]
    return head :not_found if params[:request_id] && !selected

    summary = Toybaco::Growth::UsageSummary.new(@account).read
    available = Toybaco::Growth::DraftAccess.enabled? && Toybaco::Growth::DraftAccess.generation_allowed?(@account, @user, @conversation)
    render json: { available: available, remaining: summary['remaining'],
                   result: selected && Toybaco::Growth::DraftState.new(selected).read }
  end

  def create
    selected = Toybaco::Growth::DraftStart.new(@account, @conversation, @user).create!(nonce: params[:nonce], draft: params[:draft])
    Toybaco::GrowthDraftJob.perform_later(selected.id) if selected.state == 'queued'
    render json: Toybaco::Growth::DraftState.new(selected).read, status: :accepted
  end

  def cancel
    selected = requests.find_by(id: params[:request_id])
    return head :not_found unless selected

    Toybaco::Growth::DraftResult.new(selected).fail!('cancelled')
    render json: Toybaco::Growth::DraftState.new(selected.reload).read
  end

  private

  def requests
    Toybaco::GrowthDraftRequest.where(account_id: @account.id, user_id: @user.id, conversation_id: @conversation.id)
  end

  def load_conversation
    response.headers['Cache-Control'] = 'no-store'
    @user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
    return head :unauthorized unless @user
    return head :bad_request unless valid_context_ids?

    @account = @user.account_users.find_by(account_id: params[:account_id])&.account
    @conversation = @account&.conversations&.find_by(display_id: params[:conversation_id])
    head :forbidden unless allowed_conversation?
  end

  def valid_context_ids?
    %i[account_id conversation_id].all? { |key| params[key].to_s.match?(/\A[1-9]\d*\z/) }
  end

  def allowed_conversation?
    @conversation && Toybaco::Growth::DraftAccess.allowed?(@account, @user, @conversation)
  end

  def require_same_origin_json
    valid = request.media_type == 'application/json' && request.headers['Origin'] == request.base_url &&
            [nil, '', 'same-origin'].include?(request.headers['Sec-Fetch-Site'])
    head :forbidden unless valid
  end

  def invalid_request(_error)
    render json: { error: '入力内容が変わりました。現在の内容でもう一度作成してください。' }, status: :conflict
  end

  def unavailable(error)
    render json: { error: error.message }, status: :unprocessable_entity
  end
end
