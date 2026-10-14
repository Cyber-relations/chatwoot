# frozen_string_literal: true

require 'rails_helper'

# 招待メールのリンクの実ブラウザーの経路(/app/auth/password/edit?reset_password_token=… の SPA が PUT /auth/password を送る)の契約。
# 招待された担当者(未確認)が再設定 token の生値と新しいパスワードを送ると、upstream の DeviseOverrides::PasswordsController が
# 受け取った生値の digest で利用者を引き、確認とパスワードの設定を同時に行い(reset_password_and_confirmation)、資格情報が
# HttpOnly Cookie で返ることを、SPA と同じブラウザー要求の形(X-Toybaco-Browser: 1、同一 Origin、Sec-Fetch-Site: same-origin、
# GET /toybaco/browser-session で取った CSRF token。devise_confirmation_browser_spec と同じ作法)で確かめる。
# 招待先は rake toybaco:e2e_invite_agent と同じ手順(upstream の AgentBuilder のうちメール送信を除いた部分)で作り、token の digest を
# 同じ update_columns で入れる。成功の応答本文(利用者のメールアドレスを含む)は読まない。upstream の controller は変えず、spec だけを置く。
# 招待先の確認・パスワードの設定は監査(EE の audited)を書かない(User の監査は常に無効、店舗は変わらない)ため、
# devise_confirmation_browser_spec のような監査の停止は要らない。
RSpec.describe 'Toybaco Devise password reset(ブラウザー)', type: :request do
  let(:origin) { 'https://chatwoot.test' }
  let(:browser_headers) { { 'X-Toybaco-Browser' => '1', 'Origin' => origin, 'Sec-Fetch-Site' => 'same-origin' } }
  let(:token) { SecureRandom.hex(32) }
  let(:digest) { Devise.token_generator.digest(User, :reset_password_token, token) }
  # 要件(6〜128 字、英大文字・英小文字・数字・記号を 1 字以上、半角)を満たす新しいパスワード。
  let(:password) { 'Invite!2026x' }
  let(:credential_cookies) { %w[cw_d_session_info cw_d_authenticated] }
  let(:password_columns) { %w[reset_password_token reset_password_sent_at confirmation_token confirmed_at encrypted_password] }

  before do
    host! 'chatwoot.test'
    https!
  end

  def csrf
    get '/toybaco/browser-session', headers: browser_headers
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch('csrf_token')
  end

  # 無料登録の正本で E2E の店舗と契約者を作って確認し(確認の commit 後の処理で店舗が有効になる)、rake toybaco:e2e_invite_agent と
  # 同じ手順で招待先(仮パスワード、確認の通知を止めて保存、店舗の agent、招待した人は契約者)を作って再設定 token の digest を入れる。
  def invited_agent(run)
    owner, account = Toybaco::Growth::FreeRegistration.new.register!(account_name: "e2e-consent-#{run}", user_full_name: "規約 確認 #{run}",
                                                                     email: "qa+e2e-consent-#{run}@example.com", password: 'Passw0rd!x2Y')
    expect(owner.confirm).to be(true)
    temporary = "1!aA#{SecureRandom.alphanumeric(12)}"
    invitee = User.new(email: "qa+e2e-consent-#{run}-invite@example.com", name: 'E2E 招待 担当者', password: temporary,
                       password_confirmation: temporary)
    invitee.skip_confirmation_notification!
    invitee.save!
    AccountUser.create!(account: account, user: invitee, role: :agent, inviter: owner)
    invitee.update_columns(reset_password_token: digest, reset_password_sent_at: Time.now.utc) # rubocop:disable Rails/SkipsModelValidations
    [invitee, account]
  end

  def set_password(value: token, new_password: password, headers: browser_headers.merge('X-CSRF-Token' => csrf))
    put '/auth/password', params: { reset_password_token: value, password: new_password, password_confirmation: new_password },
                          headers: headers, as: :json
  end

  def cookie_header(name)
    Array(response.headers['Set-Cookie']).flat_map { |entry| entry.split("\n") }.find { |entry| entry.start_with?("#{name}=") }
  end

  def password_state(user)
    user.reload.attributes.slice(*password_columns)
  end

  it 'ブラウザー要求の有効な token と要件を満たすパスワードで、200 と HttpOnly Cookie の資格情報を返し、認証ヘッダは出さない' do
    invited_agent('r701-1')
    set_password
    expect(response).to have_http_status(:ok)
    expect(cookie_header('cw_d_session_info')).to match(%r{; path=/}i).and match(/; secure/i).and match(/; httponly/i).and match(/; samesite=lax/i)
    expect(cookie_header('cw_d_authenticated')).to match(/; secure/i).and match(/; samesite=lax/i)
    expect(cookie_header('cw_d_authenticated')).not_to match(/; httponly/i)
    expect(%w[access-token client uid authorization].map { |name| response.headers[name] }).to all(be_nil)
  end

  it 'ブラウザー要求の設定で、確認とパスワードの設定を同時に行って両方の token を消し、招待された店舗はそのまま' do
    invitee, account = invited_agent('r706-1')
    expect([invitee.confirmed?, invitee.confirmation_token.present?]).to eq([false, true])
    set_password
    expect(response).to have_http_status(:ok)
    expect([invitee.reload.confirmed_at, invitee.valid_password?(password)]).to match([be_within(1.minute).of(Time.now.utc), true])
    expect(invitee.attributes.values_at('reset_password_token', 'reset_password_sent_at', 'confirmation_token')).to all(be_nil)
    # 招待された担当者にはメール確認待ちの店舗が無いので、確認の commit 後の処理は何もしない(店舗は有効のまま、job も積まない)。
    expect([account.reload.status, AccountUser.where(user_id: invitee.id).pluck(:account_id, :role)]).to eq(['active', [[account.id, 'agent']]])
    expect(Toybaco::FreeActivationJob).not_to have_been_enqueued
  end

  it '同じ token の 2 回目は 422(Invalid token)で、設定したパスワードを変えない' do
    invitee, = invited_agent('r702-1')
    set_password
    expect(response).to have_http_status(:ok)
    saved = password_state(invitee)
    set_password(new_password: 'Again!2026y')
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['message']).to eq('Invalid token')
    expect(password_state(invitee)).to eq(saved)
  end

  # upstream の reset_password_and_confirmation はパスワードの検証より先に確認を保存するため、要件外の 422 でも招待先は確認済みになる
  # (再設定 token は残り、設定し直せる)。確認の有無は upstream の挙動なので、ここでは契約にしない。
  it '要件を満たさないパスワードは 422 で日本語の message を返し、パスワードを変えず token を残す(設定し直せる)' do
    invitee, = invited_agent('r703-1')
    set_password(new_password: 'Abcdef12')
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['message']).to start_with('パスワード').and(satisfy { |message| !message.match?(/must contain|translation missing/i) })
    expect(credential_cookies.map { |name| cookie_header(name) }).to all(be_nil)
    expect([invitee.reload.valid_password?('Abcdef12'), invitee.reset_password_token == digest]).to eq([false, true])
    set_password
    expect(response).to have_http_status(:ok)
    expect(invitee.reload.valid_password?(password)).to be(true)
  end

  it '無効な token は 422(Invalid token)で、確認もパスワードの設定もせず、Cookie の資格情報を返さない' do
    invitee, = invited_agent('r704-1')
    saved = password_state(invitee)
    set_password(value: SecureRandom.hex(32))
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['message']).to eq('Invalid token')
    expect(credential_cookies.map { |name| cookie_header(name) }).to all(be_nil)
    expect(password_state(invitee)).to eq(saved)
  end

  it 'ブラウザー要求で CSRF token が無ければ 403 で、確認もパスワードの設定もしない' do
    invitee, = invited_agent('r705-1')
    saved = password_state(invitee)
    set_password(headers: browser_headers)
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['error']).to eq('csrf_verification_failed')
    expect(credential_cookies.map { |name| cookie_header(name) }).to all(be_nil)
    expect(password_state(invitee)).to eq(saved)
  end
end
