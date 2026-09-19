# frozen_string_literal: true

require_relative '../../../lib/toybaco/connections/handoff/verification'
require_relative '../../../lib/toybaco/connections/handoff/presentation'

class Toybaco::ConnectionHandoffSessionsController < ActionController::Base # rubocop:disable Rails/ApplicationController
  Handoff = Toybaco::Connections::Handoff
  COOKIE = :toybaco_connection_handoff
  skip_forgery_protection
  before_action :load_record
  before_action :same_origin_json, except: :show
  rescue_from Handoff::Forbidden, Handoff::Invalid, ActiveSupport::MessageEncryptor::InvalidMessage, with: :forbidden
  rescue_from Handoff::Limited, with: :limited
  rescue_from Handoff::Unavailable, with: :unavailable

  rescue_from Handoff::IncorrectCode, with: :incorrect_code

  def open
    Handoff::Access.current!(@record)
    Handoff::Access.token!(@record, params[:link_secret])
    @nonce = browser_nonce || SecureRandom.hex(32)
    cookies.encrypted[COOKIE] = { value: { 'id' => @record.public_id, 'nonce' => @nonce }, httponly: true, secure: request.ssl?, same_site: :lax,
                                  expires: @record.expires_at, path: '/toybaco/connections' }
    render json: Handoff::Presentation.recipient(@record)
  end

  def show
    Handoff::Access.receipt!(@record, browser_nonce)
    render json: Handoff::Presentation.recipient(@record)
  end

  def code
    verification.request!(token: params[:link_secret], browser_nonce: required_nonce)
    render json: Handoff::Presentation.recipient(@record.reload), status: :accepted
  end

  def verify
    verification.verify!(token: params[:link_secret], browser_nonce: required_nonce, code: params[:verification_code])
    render json: Handoff::Presentation.recipient(@record.reload)
  end

  def login
    user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
    verification.login!(token: params[:link_secret], browser_nonce: required_nonce, user: user)
    render json: Handoff::Presentation.recipient(@record.reload)
  end

  private

  def load_record
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
    raise Handoff::Forbidden unless params[:id].to_s.match?(Handoff::Access::UUID)

    @record = Toybaco::ConnectionHandoff.find_by(public_id: params[:id])
    raise Handoff::Forbidden unless @record
  end

  def same_origin_json
    valid = request.media_type == 'application/json' && request.headers['Origin'] == request.base_url &&
            [nil, '', 'same-origin'].include?(request.headers['Sec-Fetch-Site']) && request.raw_post.bytesize <= 8192
    head :forbidden unless valid
  end

  def browser_nonce
    cookie = cookies.encrypted[COOKIE]
    cookie['nonce'] if cookie.is_a?(Hash) && cookie['id'] == @record.public_id && cookie['nonce'].to_s.match?(Handoff::Access::SECRET)
  end

  def required_nonce
    browser_nonce || raise(Handoff::Forbidden)
  end

  def verification
    Handoff::Verification.new(@record)
  end

  def incorrect_code(_error = nil)
    render json: { error: '確認コードが一致しません。', verification_remaining: [5 - @record.reload.verification_attempts, 0].max },
           status: :unprocessable_entity
  end

  def forbidden(_error = nil)
    render json: { error: 'この依頼は利用できません。依頼元へ再発行をご依頼ください。' }, status: :forbidden
  end

  def limited(_error = nil)
    render json: { error: '確認回数の上限に達しました。時間をおくか、依頼元へ再発行をご依頼ください。' }, status: :too_many_requests
  end

  def unavailable(_error = nil)
    render json: { error: '接続設定を開始できません。時間をおいてお試しください。' }, status: :service_unavailable
  end
end
