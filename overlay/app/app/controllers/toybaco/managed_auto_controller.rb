# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/managed_auto_install'

class Toybaco::ManagedAutoController < Toybaco::AiReplyController
  skip_forgery_protection
  before_action :load_account
  before_action :same_origin!, only: %i[create update]
  rescue_from Toybaco::Growth::ManagedAuto::Invalid, ActiveRecord::RecordNotFound, with: :invalid
  rescue_from Toybaco::Growth::InboxRetention::Held, Toybaco::Growth::InboxRetention::Busy,
              Toybaco::Growth::InboxRetention::Invalid, with: :busy

  def show
    @state = Toybaco::Growth::ManagedAuto.public_state(Toybaco::GrowthAutoInstallation.find_by(account_id: @account.id))
    @inboxes = @account.inboxes.order(:id)
    respond_to do |format|
      format.html { render :show, layout: false }
      format.json { render json: @state.merge('enabled' => Toybaco::Growth::ManagedAuto.enabled?) }
    end
  end

  def create
    raise Toybaco::Growth::ManagedAuto::Invalid unless params[:inbox_id].is_a?(Integer) && params[:inbox_id].positive?

    result = service.create!(inbox_id: params[:inbox_id], request_id: params[:request_id])
    render json: Toybaco::Growth::ManagedAuto.public_state(result)
  end

  def update
    result = service.change!(mode: params[:mode], generation: params[:generation], epoch: params[:epoch], request_id: params[:request_id])
    render json: Toybaco::Growth::ManagedAuto.public_state(result)
  end

  private

  def service
    Toybaco::Growth::ManagedAutoInstall.new(@account.id, actor_id: @user.id)
  end

  def load_account
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Content-Security-Policy'] = "default-src 'none'; script-src 'self'; style-src 'self'; " \
                                                  "connect-src 'self'; base-uri 'none'; frame-ancestors 'self'"
    @user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
    return head :unauthorized unless @user
    return head :bad_request unless params[:account_id].to_s.match?(/\A[1-9][0-9]*\z/)

    @account = @user.account_users.find_by(account_id: params[:account_id], role: :administrator)&.account
    return head :forbidden unless @account

    Toybaco::Growth::ManagedAuto.administrator!(@account, @user.id)
  end

  def same_origin!
    allowed = request.media_type == 'application/json' && request.headers['Origin'] == request.base_url &&
              [nil, '', 'same-origin'].include?(request.headers['Sec-Fetch-Site'])
    head :forbidden unless allowed
  end

  def invalid
    render json: { error: '現在の店舗・窓口・利用条件を確認してください。ほかのBot設定は置き換えません。' }, status: :conflict
  end

  def busy
    render json: { error: '処理中の応答を確認しています。停止完了までお待ちください。' }, status: :conflict
  end
end
