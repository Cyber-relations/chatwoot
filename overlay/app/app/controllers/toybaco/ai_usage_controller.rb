# frozen_string_literal: true

require_relative '../../../lib/toybaco/ai_usage'

# Cookie reads and bot-token writes use the same explicit account boundary as
# the other Toybaco overlay endpoints, without upstream API-token filters.
class Toybaco::AiUsageController < ActionController::Base # rubocop:disable Rails/ApplicationController
  skip_forgery_protection
  before_action :load_account
  before_action :load_message, only: :update
  rescue_from Toybaco::PlanCatalog::Invalid, with: :unavailable

  def show
    render json: Toybaco::AiUsage.new(@account).summary
  end

  def update
    usage = Toybaco::AiUsage.new(@account)
    case params[:action_type]
    when 'reserve'
      return render json: { result: 'denied', reason: 'conversation_not_pending' } unless @conversation.pending?

      render json: usage.reserve(@message)
    when 'consumed', 'released'
      render json: usage.settle(@message, token: params[:token], outcome: params[:action_type])
    else
      head :bad_request
    end
  end

  private

  def load_account
    response.headers['Cache-Control'] = 'no-store'
    id = params[:account_id].to_s
    return head :bad_request unless id.match?(/\A[1-9]\d*\z/)

    return if request.get? && session_account(id)
    return if bot_account(id)

    head :unauthorized
  end

  def session_account(id)
    user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
    @account = user&.account_users&.find_by(account_id: id)&.account
  end

  def bot_account(id)
    token = request.headers['api_access_token'].presence || request.headers['Api-Access-Token'].presence
    owner = token && AccessToken.find_by(token: token)&.owner
    @bot = owner if owner.instance_of?(AgentBot)
    @account = Account.find_by(id: id) if @bot
    @account && @bot.agent_bot_inboxes.where(status: :active).joins(:inbox).exists?(inboxes: { account_id: @account.id })
  end

  def load_message
    return head :bad_request unless valid_message_ids?

    @conversation = @account.conversations.find_by(display_id: params[:conversation_id])
    return head :not_found unless @conversation && @bot.agent_bot_inboxes.where(status: :active).exists?(inbox_id: @conversation.inbox_id)

    @message = @conversation.messages.find_by(id: params[:message_id])
    head :not_found unless @message&.incoming? && !@message.private?
  end

  def valid_message_ids?
    %i[conversation_id message_id].all? { |key| params[key].to_s.match?(/\A[1-9]\d*\z/) }
  end

  def unavailable
    render json: { result: 'denied', reason: 'usage_unavailable' }, status: :service_unavailable
  end
end
