# frozen_string_literal: true

# GET /auth/confirmation は upstream では Devise 既定の show が走る。HTML を選ぶ要求の無効 token では Devise 同梱の
# confirmations/new.html.erb(Chatwoot に無い omniauth_authorize_path を呼ぶ)を描いて無認証の 500 になり、
# HTML 以外の要求では確認(confirm_by_token)を済ませてから 406 を返していた。
# 利用者の確認 URL は SPA 経路(/app/auth/confirmation、確認そのものは SPA の POST)なので、この module は show を
# 完全に置き換え(super は呼ばない)、GET では確認しない。HTML を選ぶ要求は形の合う token だけを SPA へ相対 Location の
# 302 で送り、token が無い・形が合わない場合は 404 で値を反射しない。HTML 以外は upstream と同じ 406 を副作用なしで返す。
module Toybaco::Security::ConfirmationShowRedirect
  CONFIRMATION_TOKEN_FORMAT = /\A[A-Za-z0-9_-]{1,128}\z/
  SPA_CONFIRMATION_PATH = '/app/auth/confirmation'

  def show
    # Devise が HTML を選ぶ条件と同じにする。Devise の候補は実質 :html だけで、negotiate_mime は formats 全体を走査し、
    # */* があっても html を選ぶ。Rails 7.2 の Accept: */* は html? が偽の Mime::Type になるので Mime::ALL とも比べる。
    return head :not_acceptable unless request.formats.any? { |mime| mime == Mime::ALL || mime.html? }

    token = params[:confirmation_token]
    return head :not_found unless token.is_a?(String) && CONFIRMATION_TOKEN_FORMAT.match?(token)

    # redirect_to は request の Host で絶対 URL 化するため、head の location: で相対 Location をそのまま返す。
    head :found, location: "#{SPA_CONFIRMATION_PATH}?#{{ confirmation_token: token }.to_query}"
  end
end
