# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/free_registration'

class Toybaco::FreeRegistrationsController < ActionController::Base # rubocop:disable Rails/ApplicationController
  protect_from_forgery with: :exception
  before_action :require_available

  def show
    render_form
  end

  def verify_email
    render 'toybaco/free_registrations/verify_email', layout: false
  end

  def create
    return render_error('利用規約とプライバシーポリシーをご確認ください。', :unprocessable_entity) unless params[:accept_terms] == '1'

    captcha_message = captcha_error
    return render_error(captcha_message, :unprocessable_entity) if captcha_message

    user, = Toybaco::Growth::FreeRegistration.new.register!(registration_attributes)
    # A confirmation email is the only next step. No session, usable store or
    # AI quota is issued to an unverified address.
    respond_to do |format|
      format.json { render json: { email: user.email, next: 'verify_email' }, status: :accepted }
      format.html { redirect_to '/toybaco/free/verify-email', status: :see_other }
    end
  rescue CustomExceptions::Account::UserExists, ActiveRecord::RecordNotUnique
    render_error('このメールは登録済みです。ログインしてください。', :conflict)
  rescue CustomExceptions::Account::InvalidEmail, CustomExceptions::Account::UserErrors, ActiveRecord::RecordInvalid,
         ActionController::ParameterMissing
    render_error('入力内容を確認してください。', :unprocessable_entity)
  end

  private

  def require_available
    response.headers['Cache-Control'] = 'no-store'
    # no-referrer makes browsers send `Origin: null` with a form POST, which forgery protection rejects.
    response.headers['Referrer-Policy'] = 'same-origin'
    head :not_found unless Toybaco::Growth::FreeRegistration.enabled?
  end

  def render_form(status: :ok)
    # server keyが空ならcaptcha_errorは検査しない。site keyだけが残った構成で部品と送信前の確認を出すと、
    # hCaptchaを読み込めない人の送信が画面側で止まって先へ進めないため、どちらも出さない。
    server_key = GlobalConfigService.load('HCAPTCHA_SERVER_KEY', '')
    @captcha_site_key = server_key.present? ? GlobalConfigService.load('HCAPTCHA_SITE_KEY', '') : ''
    render 'toybaco/free_registrations/show', layout: false, status: status
  end

  def render_error(message, status)
    @error = message
    respond_to do |format|
      format.json { render json: { error: message }, status: status }
      format.html { render_form(status: status) }
    end
  end

  # server keyが未設定なら検査しない(上流ChatwootCaptchaと同じ)。tokenが無いのはチェック前の送信や
  # 部品の読み込み失敗で、hCaptchaに検証を断られた場合とは利用者のすることが違うので文言を分ける。
  def captcha_error
    server_key = GlobalConfigService.load('HCAPTCHA_SERVER_KEY', '')
    return if server_key.blank?

    token = params[:h_captcha_client_response].presence || params['h-captcha-response'].presence
    return '「私は人間です」の確認にチェックを入れてから送信してください。確認欄が表示されない場合はページを再読み込みしてください。' if token.blank?

    '確認に失敗しました。もう一度お試しください。' unless ChatwootCaptcha.new(token).valid?
  end

  def registration_attributes
    { account_name: params.require(:account_name).to_s.strip.first(100), user_full_name: params.require(:user_full_name).to_s.strip.first(100),
      email: params.require(:email).to_s.strip.downcase, password: params.require(:password).to_s }
  end
end
