# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'SuperAdmin MFA boundary', type: :request do
  let(:admin) { create(:super_admin, otp_secret: User.generate_otp_secret, otp_required_for_login: true, otp_backup_codes: ['ABCDEF12']) }
  let(:login_path) { '/super_admin/sign_in' }

  before do
    allow(ViteRuby.instance).to receive(:dev_server_running?).and_return(true)
  end

  def login(user = admin, **overrides)
    post login_path, params: { super_admin: { email: user.email, password: 'Password1!' }.merge(overrides) }
  end

  def expect_denied
    expect(response).to redirect_to(login_path)
    get '/super_admin/accounts'
    expect(response).to redirect_to(login_path)
  end

  it 'rejects password-only login even when the user has enrolled MFA' do
    login
    expect_denied
  end

  it 'rejects an incorrect password without consuming a valid backup code' do
    login(password: 'wrong', backup_code: 'ABCDEF12')
    expect_denied
    expect(admin.reload.otp_backup_codes).to eq(['ABCDEF12'])
  end

  it 'rejects missing and malformed credential parameters without authentication' do
    [nil, 'malformed', []].each do |input|
      post login_path, params: { super_admin: input }
      expect_denied
    end
  end

  it 'rejects an incorrect second factor' do
    login(otp_code: 'not-a-code')
    expect_denied
  end

  it 'accepts and consumes a real TOTP, then permits the protected controller' do
    login(otp_code: admin.current_otp)
    expect(response).to redirect_to('/super_admin')
    get '/super_admin/accounts'
    expect(response).to have_http_status(:ok)
    expect(response.headers['Cache-Control']).to eq('private, no-store')
    expect(admin.reload.consumed_timestep).to be_present
  end

  it 'rejects replay of a consumed TOTP' do
    code = admin.current_otp
    login(otp_code: code)
    delete '/super_admin/sign_out'
    login(otp_code: code)
    expect_denied
  end

  it 'accepts a backup code once and rejects its reuse after logout' do
    login(backup_code: 'abcdef12')
    expect(response).to redirect_to('/super_admin')
    expect(admin.reload.otp_backup_codes).to eq(['XXXXXXXX'])
    delete '/super_admin/sign_out'
    login(backup_code: 'ABCDEF12')
    expect_denied
  end

  it 'does not create an admin session before enrollment' do
    admin.update!(otp_required_for_login: false)
    login(backup_code: 'ABCDEF12')
    expect_denied
    get login_path
    expect(response.body).to include('二段階認証を設定してください')
  end

  it 'rejects an unconfirmed administrator without consuming a code' do
    admin.update!(confirmed_at: nil)
    login(backup_code: 'ABCDEF12')
    expect_denied
    expect(admin.reload.otp_backup_codes).to eq(['ABCDEF12'])
  end

  it 'rejects a pre-rollout Warden session on controllers, CSV and the mounted monitor' do
    paths = %w[/super_admin/accounts /super_admin/toybaco_stores.csv /monitoring/sidekiq /monitoring//sidekiq/queues /%73uper_admin/accounts]
    paths.each do |path|
      sign_in(admin, scope: :super_admin)
      get path
      expect(response).to redirect_to(login_path)
    end
  end

  it 'permits the mounted monitor after MFA' do
    login(backup_code: 'ABCDEF12')
    get '/monitoring/sidekiq'
    expect(response).to have_http_status(:ok)
  end

  it 'rejects a copied cookie after logout has revoked its server proof' do
    login(backup_code: 'ABCDEF12')
    old_cookie = cookies['_chatwoot_session']
    delete '/super_admin/sign_out'
    cookies['_chatwoot_session'] = old_cookie
    get '/super_admin/accounts'
    expect(response).to redirect_to(login_path)
  end

  it 'expires proof after twelve hours even if the Rails cookie still exists' do
    login(backup_code: 'ABCDEF12')
    travel 12.hours do
      get '/super_admin/accounts'
      expect(response).to redirect_to(login_path)
    end
  end

  it 'rejects a session after the MFA secret changes' do
    login(backup_code: 'ABCDEF12')
    admin.update!(otp_secret: User.generate_otp_secret)
    get '/super_admin/accounts'
    expect(response).to redirect_to(login_path)
  end

  it 'rejects a session after MFA is disabled' do
    login(backup_code: 'ABCDEF12')
    admin.update!(otp_required_for_login: false)
    get '/super_admin/accounts'
    expect(response).to redirect_to(login_path)
  end

  it 'rejects a session after the password changes' do
    login(backup_code: 'ABCDEF12')
    admin.update!(password: 'AnotherPassword2!')
    get '/super_admin/accounts'
    expect(response).to redirect_to(login_path)
  end

  it 'does not grant admin scope to an ordinary user with a valid OTP' do
    user = create(:user, otp_secret: User.generate_otp_secret, otp_required_for_login: true)
    login(user, otp_code: user.current_otp)
    expect_denied
  end

  it 'fails closed if the server proof store is unavailable' do
    login(backup_code: 'ABCDEF12')
    allow(Redis::Alfred).to receive(:get).and_raise(Redis::CannotConnectError)
    get '/super_admin/accounts'
    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).not_to include(admin.email)
  end

  it 'binds proof to the same user and rejects a substituted Warden identity' do
    login(backup_code: 'ABCDEF12')
    other = create(:super_admin, otp_secret: User.generate_otp_secret, otp_required_for_login: true)
    sign_in(other, scope: :super_admin)
    get '/super_admin/accounts'
    expect(response).to redirect_to(login_path)
  end

  it 'throttles attempts for the same normalized admin email across different IPs' do
    original = Rack::Attack.enabled
    Rack::Attack.enabled = true
    6.times do |index|
      post(index == 5 ? '/%73uper_admin/sign_in/' : login_path,
           params: { super_admin: { email: " #{admin.email.upcase} ", password: 'wrong' } },
           env: { 'REMOTE_ADDR' => "198.51.100.#{index + 10}" })
      expect(response.status).to eq(index == 5 ? 429 : 302)
    end
  ensure
    Rack::Attack.enabled = original
  end

  it 'throttles a single IP even when it rotates email addresses' do
    original = Rack::Attack.enabled
    Rack::Attack.enabled = true
    6.times do |index|
      post login_path, params: { super_admin: { email: "#{SecureRandom.hex(8)}@example.invalid", password: 'wrong' } },
                       env: { 'REMOTE_ADDR' => '198.51.100.50' }
      expect(response.status).to eq(index == 5 ? 429 : 302)
    end
  ensure
    Rack::Attack.enabled = original
  end

  it 'does not put unrelated admin emails into one shared throttle bucket' do
    original = Rack::Attack.enabled
    Rack::Attack.enabled = true
    6.times do |index|
      post login_path, params: { super_admin: { email: "#{SecureRandom.hex(8)}@example.invalid", password: 'wrong' } },
                       env: { 'action_dispatch.show_exceptions' => :none, 'REMOTE_ADDR' => "198.51.100.#{index + 30}" }
      expect(response.status).to eq(302)
    end
  ensure
    Rack::Attack.enabled = original
  end

  it 'requires a CSRF token for login and accepts the token from its own form' do
    original = SuperAdmin::Devise::SessionsController.allow_forgery_protection
    SuperAdmin::Devise::SessionsController.allow_forgery_protection = true
    login(backup_code: 'ABCDEF12')
    expect(response).to have_http_status(:unprocessable_content)
    get login_path, env: { 'action_dispatch.show_exceptions' => :none }
    csrf = Nokogiri::HTML(response.body).at_css('input[name="authenticity_token"]')['value']
    post login_path, params: { authenticity_token: csrf, super_admin: { email: admin.email, password: 'Password1!', backup_code: 'ABCDEF12' } }
    expect(response).to redirect_to('/super_admin')
  ensure
    SuperAdmin::Devise::SessionsController.allow_forgery_protection = original
  end
end
