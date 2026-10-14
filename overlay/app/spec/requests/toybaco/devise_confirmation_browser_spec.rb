# frozen_string_literal: true

require 'rails_helper'

# 確認メールのリンクの実ブラウザーの経路(/app/auth/confirmation の SPA が POST /auth/confirmation を送る)の契約。
# devise_auth_headers_spec はブラウザー印の無い POST /auth/confirmation(資格情報をヘッダで返す)だけを見ているため、ここでは
# SPA と同じブラウザー要求の形(X-Toybaco-Browser: 1、同一 Origin、Sec-Fetch-Site: same-origin、GET /toybaco/browser-session で
# 取った CSRF token。browser_session_spec と同じ作法)で送り、資格情報が HttpOnly Cookie で返ること、無料登録の店舗が同じ要求の中で
# 有効になること(Growth::FreeConfirmation の commit 後の処理。FreeActivationJob には逃げない)を確かめる。
# 利用者は無料登録の正本(FreeRegistration#register!)で作った E2E 風の契約者(店舗はメール確認待ち)で、token は
# rake toybaco:e2e_confirmation_token と同じ update_columns で入れる。成功の応答本文(利用者のメールアドレスを含む)は読まない。
# upstream の controller(DeviseOverrides::ConfirmationsController)は変えず、spec だけを置く。
RSpec.describe 'Toybaco Devise confirmation(ブラウザー)', type: :request do
  let(:origin) { 'https://chatwoot.test' }
  let(:browser_headers) { { 'X-Toybaco-Browser' => '1', 'Origin' => origin, 'Sec-Fetch-Site' => 'same-origin' } }
  let(:token) { SecureRandom.hex(32) }
  let(:credential_cookies) { %w[cw_d_session_info cw_d_authenticated] }

  before do
    host! 'chatwoot.test'
    https!
  end

  # production・staging は CE(infra/terraform/ecs.tf の DISABLE_ENTERPRISE=true)で、監査(audited)を持つモデルは EE の
  # Enterprise::Audit::* だけ。test は EE が有効で、確認の commit 後の店舗の有効化(Account#update!)の監査が操作者を DTA の
  # current_user に求め、DeviseController#resource_class(引数 0)と衝突して 500 になる(#375 と同じ衝突の、EE だけの経路)。
  # 本番と同じく監査の無い状態で確かめるため、この spec の間だけ監査を止める。
  around do |example|
    previous = Audited.auditing_enabled
    Audited.auditing_enabled = false
    example.run
  ensure
    Audited.auditing_enabled = previous
  end

  def csrf
    get '/toybaco/browser-session', headers: browser_headers
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch('csrf_token')
  end

  # 無料登録の正本で、メール確認待ちの店舗(停止中)と未確認の契約者を作り、確認 token を入れる(callback とメールの送信を通さない)。
  def pending_registration(run, sent_at: Time.now.utc)
    user, account = Toybaco::Growth::FreeRegistration.new.register!(account_name: "e2e-consent-#{run}", user_full_name: "規約 確認 #{run}",
                                                                    email: "qa+e2e-consent-#{run}@example.com", password: 'Passw0rd!x2Y')
    user.update_columns(confirmation_token: token, confirmation_sent_at: sent_at) # rubocop:disable Rails/SkipsModelValidations
    [user, account]
  end

  def confirm_in_browser
    post '/auth/confirmation', params: { confirmation_token: token }, headers: browser_headers.merge('X-CSRF-Token' => csrf), as: :json
  end

  def phase(account)
    account.reload.internal_attributes.dig('toybaco_growth_registration', 'phase')
  end

  def cookie_header(name)
    Array(response.headers['Set-Cookie']).flat_map { |entry| entry.split("\n") }.find { |entry| entry.start_with?("#{name}=") }
  end

  it 'ブラウザー要求の有効な token で確認し、200 と HttpOnly Cookie の資格情報を返し、認証ヘッダは出さない' do
    pending_registration('r501-1')
    confirm_in_browser
    expect(response).to have_http_status(:ok)
    expect(cookie_header('cw_d_session_info')).to match(%r{; path=/}i).and match(/; secure/i).and match(/; httponly/i).and match(/; samesite=lax/i)
    expect(cookie_header('cw_d_authenticated')).to match(/; secure/i).and match(/; samesite=lax/i)
    expect(cookie_header('cw_d_authenticated')).not_to match(/; httponly/i)
    expect(cookies['cw_d_authenticated']).to match(/\A[a-f0-9]{64}\z/)
    expect(%w[access-token client uid authorization].map { |name| response.headers[name] }).to all(be_nil)
  end

  it 'ブラウザー要求の確認で confirmed_at が入り、無料登録の店舗が同じ要求の中で有効になる(FreeActivationJob を積まない)' do
    user, account = pending_registration('r502-1')
    expect([user.confirmed_at, account.status, phase(account)]).to eq([nil, 'suspended', 'email_pending'])
    confirm_in_browser
    expect(response).to have_http_status(:ok)
    expect(user.reload.confirmed_at).to be_within(1.minute).of(Time.now.utc)
    expect([account.reload.status, phase(account)]).to eq(%w[active active])
    expect(Toybaco::FreeActivationJob).not_to have_been_enqueued
  end

  it '送信から 24 時間を過ぎた token は 422(Failure)で確認せず、Cookie の資格情報も店舗の有効化も残さない' do
    user, account = pending_registration('r503-1', sent_at: 25.hours.ago)
    confirm_in_browser
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['message']).to eq('Failure')
    expect(credential_cookies.map { |name| cookie_header(name) }).to all(be_nil)
    expect([user.reload.confirmed_at, account.reload.status, phase(account)]).to eq([nil, 'suspended', 'email_pending'])
  end

  it '同じ token の 2 回目は 422(Already confirmed)で、確認の時刻を変えない' do
    user, = pending_registration('r504-1')
    confirm_in_browser
    expect(response).to have_http_status(:ok)
    confirmed_at = user.reload.confirmed_at
    confirm_in_browser
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['message']).to eq('Already confirmed')
    expect(user.reload.confirmed_at).to eq(confirmed_at)
  end

  it 'ブラウザー要求で CSRF token が無ければ 403 で確認せず、店舗も有効にしない' do
    user, account = pending_registration('r505-1')
    post '/auth/confirmation', params: { confirmation_token: token }, headers: browser_headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['error']).to eq('csrf_verification_failed')
    expect([user.reload.confirmed_at, phase(account)]).to eq([nil, 'email_pending'])
  end

  it 'ブラウザー印の無い POST は従来どおり資格情報をヘッダで返して Cookie は出さず、店舗の有効化は同じ' do
    user, account = pending_registration('r506-1')
    post '/auth/confirmation', params: { confirmation_token: token }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.headers.values_at('access-token', 'client', 'uid')).to all(be_present)
    expect(credential_cookies.map { |name| cookie_header(name) }).to all(be_nil)
    expect([user.reload.confirmed?, account.reload.status, phase(account)]).to eq([true, 'active', 'active'])
  end
end
