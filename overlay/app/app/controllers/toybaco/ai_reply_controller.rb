# frozen_string_literal: true

require_relative '../../../lib/toybaco/ai_reply_mode'
require_relative '../../../lib/toybaco/growth/bot_access'
require_relative '../../../lib/toybaco/growth/reply_policy'

# 受信箱の AI 一次応答モード(全自動 / 下書き)。客面は日本語のみ。
# 店舗スタッフはログインcookie、bot は既存の api_access_token で読む。
# bot が受信箱を指定したときだけ、その受信箱へ自動応答してよいかの判定(access)を付ける。
class Toybaco::AiReplyController < ActionController::Base # rubocop:disable Rails/ApplicationController
  skip_forgery_protection
  before_action :set_no_cache
  before_action :load_account

  def show
    payload = Toybaco::AiReplyMode.payload(Toybaco::AiReplyMode.read_from(@account))
    payload[:meter] = Toybaco::GrowthTerms::METER if Toybaco::Entitlements.for_account(@account)&.dig('ai_meter') == Toybaco::GrowthTerms::METER
    access = bot_access
    payload[:access] = access if access
    render json: payload
  end

  def update
    return head :forbidden unless @account_user
    return update_growth if Toybaco::Entitlements.for_account(@account)&.dig('ai_meter') == Toybaco::GrowthTerms::METER

    mode = Toybaco::AiReplyMode.write_to!(@account, params[:mode])
    render json: Toybaco::AiReplyMode.payload(mode)
  end

  private

  # cookie の呼出しと受信箱なしの呼出しは応答を変えない。判定は1行だけ記録する(店舗・受信箱・botのIDと結果のみ)。
  def bot_access
    inbox_id = params[:inbox_id].to_s
    return unless @bot && inbox_id.match?(/\A[1-9]\d*\z/)

    access = Toybaco::Growth::BotAccess.read(@account, inbox: @account.inboxes.find_by(id: inbox_id), bot: @bot)
    Rails.logger.info("toybaco_bot_access account=#{@account.id} inbox=#{inbox_id} bot=#{@bot.id} " \
                      "allowed=#{access['allowed']} reason=#{access['reason']}")
    access
  end

  def update_growth
    allowed_site = [nil, '', 'same-origin'].include?(request.headers['Sec-Fetch-Site'])
    return head :forbidden unless request.media_type == 'application/json' && request.headers['Origin'] == request.base_url && allowed_site

    mode = Toybaco::Growth::ReplyPolicy.new(@account).write!(params[:mode], membership: @account_user)
    render json: Toybaco::AiReplyMode.payload(mode)
  rescue ArgumentError
    render json: { error: 'AIの利用条件と店舗情報を確認してください。' }, status: :unprocessable_entity
  end

  def load_account
    account_id = params[:account_id].to_s
    return head :bad_request unless account_id.match?(/\A\d+\z/)
    return if assign_session_account(account_id)
    return if request.get? && assign_bot_account(account_id)

    head :unauthorized
  end

  def assign_session_account(account_id)
    user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
    return false unless user

    @account_user = user.account_users.find_by(account_id: account_id)
    return false unless @account_user

    @account = @account_user.account
    true
  end

  def assign_bot_account(account_id)
    bot = agent_bot_from_request
    return false unless bot

    account = Account.find_by(id: account_id)
    return false unless account && bot_covers_account?(bot, account)

    @account = account
    @bot = bot
    true
  end

  def agent_bot_from_request
    token = request.headers['api_access_token'].presence || request.headers['Api-Access-Token'].presence
    return unless token && defined?(AccessToken) && defined?(AgentBot)

    owner = AccessToken.find_by(token: token)&.owner
    owner if owner.instance_of?(AgentBot)
  end

  def bot_covers_account?(bot, account)
    return false unless bot && account
    return true unless bot.respond_to?(:agent_bot_inboxes)

    bot.agent_bot_inboxes.joins(:inbox).exists?(inboxes: { account_id: account.id })
  rescue StandardError
    false
  end

  def set_no_cache
    response.headers['Cache-Control'] = 'no-store'
  end
end
