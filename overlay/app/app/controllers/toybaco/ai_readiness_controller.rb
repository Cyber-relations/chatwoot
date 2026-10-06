# frozen_string_literal: true

require_relative '../../../lib/toybaco/ai_readiness'
require_relative '../../../lib/toybaco/ai_inbox_status'

class Toybaco::AiReadinessController < ActionController::Base # rubocop:disable Rails/ApplicationController
  before_action :load_account
  rescue_from ActiveRecord::ActiveRecordError, with: :unavailable

  def show
    result = Toybaco::AiReadiness.for_account(@account)
    visible = visible_inbox_ids
    if params.key?(:conversation_id)
      conversation = authorized_conversation
      return head :not_found unless conversation

      visible << conversation.inbox_id
      result = result.merge('conversation_inbox_id' => conversation.inbox_id)
    end
    status = Toybaco::AiInboxStatus.for_account(@account)
    inboxes = status['inboxes'].select { |inbox| visible.include?(inbox['id']) }
    render json: result.merge('mode' => status['mode'], 'inboxes' => inboxes).merge(member_summary)
  end

  private

  def load_account
    response.headers['Cache-Control'] = 'no-store'
    id = params[:account_id].to_s
    return head :bad_request unless id.match?(/\A[1-9]\d*\z/)

    @user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
    @membership = @user&.account_users&.find_by(account_id: id)
    @account = @membership&.account
    head :unauthorized unless @account
  end

  # 会話 0 件の案内(post-entry)は管理者にだけ出す。担当者の会話一覧は所属する受信箱に絞られるので、
  # 店舗全体の会話数(権限で絞らない数)は管理者にだけ返す。
  def member_summary
    return { 'administrator' => false } unless @membership.administrator?

    { 'administrator' => true, 'conversation_total' => @account.conversations.count }
  end

  # The inboxes the dashboard lists for this member (User#assigned_inboxes without Current).
  def visible_inbox_ids
    scope = @membership.administrator? ? @account.inboxes : @user.inboxes.where(account_id: @account.id)
    scope.pluck(:id)
  end

  # The composer sends the conversation number shown in the URL (display_id).
  def authorized_conversation
    id = params[:conversation_id].to_s
    return unless id.match?(/\A[1-9]\d*\z/)

    conversation = @account.conversations.find_by(display_id: id)
    context = { user: @user, account: @account, account_user: @membership }
    conversation if conversation && ConversationPolicy.new(context, conversation).show?
  end

  def unavailable
    render json: { 'connection' => 'unknown' }, status: :service_unavailable
  end
end
