# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Application administrator MFA', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:headers) { { 'Origin' => 'https://chatwoot.test', 'X-Toybaco-Browser' => '1', 'Sec-Fetch-Site' => 'same-origin' } }

  before do
    allow(ViteRuby.instance).to receive(:dev_server_running?).and_return(true)
    host! 'chatwoot.test'
    https!
  end

  def csrf
    get '/toybaco/browser-session', headers: headers
    response.parsed_body.fetch('csrf_token')
  end

  def login(params = {})
    post '/auth/sign_in', params: { email: user.email, password: 'Password1!' }.merge(params),
                          headers: headers.merge('X-CSRF-Token' => csrf), as: :json
  end

  def enable_mfa
    user.update!(otp_secret: User.generate_otp_secret, otp_required_for_login: true, otp_backup_codes: %w[ABCD1234 EFGH5678])
  end

  def complete_mfa
    login
    challenge = response.parsed_body.fetch('mfa_token')
    login(mfa_token: challenge, backup_code: 'ABCD1234')
    expect(response).to have_http_status(:ok)
    challenge
  end

  def mfa_verified_at(client)
    Time.zone.at(user.reload.tokens.dig(client, 'toybaco_mfa_at'))
  end

  def device_verified_after?(duration)
    client = JSON.parse(cookies['cw_d_session_info'])['client']
    travel_to(mfa_verified_at(client) + duration) { Toybaco::Security::ApplicationMfaSession.valid?(user.reload, client) }
  end

  # Store administrators enroll optionally (owner decision, 2026-10-06).
  it 'lets an unenrolled store administrator sign in without MFA proof' do
    login
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['mfa_enrollment_required']).to be_nil
    payload = JSON.parse(cookies['cw_d_session_info'])
    expect(user.reload.tokens.dig(payload['client'], 'toybaco_mfa_proof')).to be_nil
    expect(Toybaco::Security::ApplicationMfaSession.valid?(user, payload['client'])).to be(true)
    get '/api/v1/profile', headers: headers
    expect(response).to have_http_status(:ok)
  end

  it 'requires MFA proof on an administrator device only once the administrator enables MFA' do
    token = user.create_new_auth_token
    expect(user.valid_token?(token['access-token'], token['client'])).to be(true)
    enable_mfa
    token = user.create_new_auth_token
    expect(user.valid_token?(token['access-token'], token['client'])).to be(false)
  end

  it 'allows an ordinary agent without imposing an administrator enrollment' do
    user.account_users.each { |membership| membership.update!(role: :agent) }
    login
    expect(response).to have_http_status(:ok)
    get '/api/v1/profile', headers: headers
    expect(response).to have_http_status(:ok)
  end

  it 'binds a successful MFA login to its live device and preserves proof during normal token rotation' do
    enable_mfa
    complete_mfa
    2.times do
      get '/api/v1/profile', headers: headers
      expect(response).to have_http_status(:ok)
    end
    payload = JSON.parse(cookies['cw_d_session_info'])
    expect(Toybaco::Security::ApplicationMfaSession.valid?(user.reload, payload['client'])).to be(true)
  end

  it 'requires MFA for SSO instead of trusting the enrollment flag' do
    enable_mfa
    sso = user.generate_sso_auth_token
    login(password: nil, sso_auth_token: sso)
    expect(response).to have_http_status(:partial_content)
    expect(response.parsed_body['mfa_required']).to be(true)
    expect(user.reload.tokens).to be_empty
    expect(user.valid_sso_auth_token?(sso)).to be(false)
  end

  it 'consumes the primary challenge once, including when a second backup code remains valid' do
    enable_mfa
    challenge = complete_mfa
    login(mfa_token: challenge, backup_code: 'EFGH5678')
    expect(response).to have_http_status(:unauthorized)
    expect(user.reload.otp_backup_codes).to include('EFGH5678')
  end

  it 'rejects a primary challenge after the password changes' do
    enable_mfa
    login
    challenge = response.parsed_body.fetch('mfa_token')
    user.update!(password: 'ChangedPassword1!')
    login(mfa_token: challenge, backup_code: 'ABCD1234')
    expect(response).to have_http_status(:unauthorized)
  end

  it 'rejects another signed token purpose at the MFA endpoint' do
    enable_mfa
    token = BaseTokenService.new(payload: { user_id: user.id, exp: 5.minutes.from_now.to_i }).generate_token
    login(mfa_token: token, backup_code: 'ABCD1234')
    expect(response).to have_http_status(:unauthorized)
  end

  it 'keeps an agent device valid when the agent is promoted to administrator' do
    user.account_users.each { |membership| membership.update!(role: :agent) }
    login
    payload = JSON.parse(cookies['cw_d_session_info'])
    user.account_users.each { |membership| membership.update!(role: :administrator) }
    expect(user.reload.valid_token?(payload['access-token'], payload['client'])).to be(true)
    expect(Toybaco::Oidc::SessionReader.record_digest(user, payload['client'])).to be_present
  end

  it 'expires the MFA proof even while the DTA device record has time remaining' do
    enable_mfa
    complete_mfa
    payload = JSON.parse(cookies['cw_d_session_info'])
    verified_at = mfa_verified_at(payload['client'])
    with_modified_env(TOYBACO_APPLICATION_MFA_MAX_AGE_HOURS: nil) do
      travel_to(verified_at + 30.days - 1.second) do
        expect(user.reload.valid_token?(payload['access-token'], payload['client'])).to be(true)
        expect(Toybaco::Oidc::SessionReader.record_digest(user, payload['client'])).to be_present
      end
      travel_to(verified_at + 30.days) do
        expect(user.reload.valid_token?(payload['access-token'], payload['client'])).to be(false)
        expect(Toybaco::Oidc::SessionReader.record_digest(user, payload['client'])).to be_nil
      end
    end
  end

  it 'lets the MFA proof lifetime be shortened in whole hours' do
    enable_mfa
    complete_mfa
    lifetimes = { '1' => 1.hour, '01' => 1.hour, "4\n" => 4.hours, '12' => 12.hours, ' 12 ' => 12.hours, '720' => 30.days }
    lifetimes.each do |hours, lifetime|
      with_modified_env(TOYBACO_APPLICATION_MFA_MAX_AGE_HOURS: hours) do
        expect(device_verified_after?(lifetime - 1.second)).to be(true), "#{hours.inspect} ended the proof before #{lifetime.inspect}"
        expect(device_verified_after?(lifetime)).to be(false), "#{hours.inspect} kept the proof past #{lifetime.inspect}"
      end
    end
  end

  it 'falls back to twelve hours for an invalid lifetime without raising' do
    enable_mfa
    complete_mfa
    ['0', '000', '721', '1000', 'abc', '12.5', '+12', '1_0', '-1', '１２', "\xFF"].each do |hours|
      with_modified_env(TOYBACO_APPLICATION_MFA_MAX_AGE_HOURS: hours) do
        expect(device_verified_after?(12.hours - 1.second)).to be(true), "#{hours.inspect} ended the proof before 12 hours"
        expect(device_verified_after?(12.hours)).to be(false), "#{hours.inspect} kept the proof past 12 hours"
      end
    end
  end

  it 'keeps thirty days for an empty or blank lifetime' do
    enable_mfa
    complete_mfa
    ['', ' ', "\n"].each do |hours|
      with_modified_env(TOYBACO_APPLICATION_MFA_MAX_AGE_HOURS: hours) do
        expect(device_verified_after?(30.days - 1.second)).to be(true), "#{hours.inspect} ended the proof before 30 days"
        expect(device_verified_after?(30.days)).to be(false), "#{hours.inspect} kept the proof past 30 days"
      end
    end
  end

  it 'rejects an MFA proof dated in the future' do
    enable_mfa
    complete_mfa
    payload = JSON.parse(cookies['cw_d_session_info'])
    future = 1.hour.from_now.to_i
    user.reload.tokens[payload['client']]['toybaco_mfa_at'] = future
    user.save!
    expect(user.reload.tokens.dig(payload['client'], 'toybaco_mfa_at')).to eq(future)
    expect(user.valid_token?(payload['access-token'], payload['client'])).to be(false)
  end

  it 'keeps the DTA device record at least as long as the thirty-day MFA proof' do
    expect(DeviseTokenAuth.token_lifespan).to be >= 30.days
  end

  it 'invalidates every device when MFA is disabled' do
    enable_mfa
    complete_mfa
    user.disable_two_factor!
    expect(user.reload.tokens).to be_empty
    get '/api/v1/profile', headers: headers
    expect(response).to have_http_status(:unauthorized)
  end

  context 'when a store administrator opts in from the profile' do
    def profile_mfa(method, path = '', params = {})
      public_send(method, "/api/v1/profile/mfa#{path}", params: params, headers: headers.merge('X-CSRF-Token' => csrf), as: :json)
    end

    # One protocol trace covers the profile opt-in from the QR code to the next dashboard request.
    it 'keeps the verifying device with MFA proof and revokes every other device' do # rubocop:disable RSpec/MultipleExpectations
      login
      client = JSON.parse(cookies['cw_d_session_info'])['client']
      other = user.reload.create_new_auth_token['client']
      get '/api/v1/profile/mfa', headers: headers
      expect(response).to have_http_status(:ok)
      profile_mfa(:post)
      expect(response).to have_http_status(:ok)
      expect(user.reload.tokens.keys).to contain_exactly(client, other)
      profile_mfa(:post, '/verify', otp_code: user.current_otp)
      expect(response).to have_http_status(:ok)
      expect(user.reload.mfa_enabled?).to be(true)
      expect(user.tokens.keys).to eq([client])
      expect(user.tokens[client]).to include('toybaco_mfa_at', 'toybaco_mfa_proof')
      expect(Toybaco::Security::ApplicationMfaSession.valid?(user, client)).to be(true)
      expect(Toybaco::Security::ApplicationMfaSession.valid?(user, other)).to be(false)
      get '/api/v1/profile', headers: headers
      expect(response).to have_http_status(:ok)
    end

    it 'keeps every device when the verification code is wrong' do
      login
      client = JSON.parse(cookies['cw_d_session_info'])['client']
      other = user.reload.create_new_auth_token['client']
      profile_mfa(:post)
      profile_mfa(:post, '/verify', otp_code: 'not-an-otp')
      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.reload.mfa_enabled?).to be(false)
      expect(user.tokens.keys).to contain_exactly(client, other)
    end

    # Verification is not a sign-in: a user whose MFA is already on gets no fresh proof from it, with any code.
    it 'never refreshes the proof of a user whose MFA is already on' do
      enable_mfa
      complete_mfa
      client = JSON.parse(cookies['cw_d_session_info'])['client']
      verified_at = user.reload.tokens.dig(client, 'toybaco_mfa_at')
      travel 1.hour do
        profile_mfa(:post, '/verify', otp_code: 'not-an-otp')
        expect(response).to have_http_status(:unprocessable_entity)
        profile_mfa(:post, '/verify', otp_code: user.reload.current_otp)
        expect(response).to have_http_status(:unprocessable_entity)
      end
      expect(user.reload.tokens.dig(client, 'toybaco_mfa_at')).to eq(verified_at)
    end

    it 'revokes every device, including the current one, when MFA is disabled from the profile' do
      login
      profile_mfa(:post)
      profile_mfa(:post, '/verify', otp_code: user.reload.current_otp)
      profile_mfa(:delete, '', password: 'Password1!', backup_code: response.parsed_body.fetch('backup_codes').first)
      expect(response).to have_http_status(:ok)
      expect(user.reload.mfa_enabled?).to be(false)
      expect(user.tokens).to be_empty
    end
  end

  context 'when a device receives MFA proof outside the sign-in' do
    it 'does not write back a device that another request removed after the user was loaded' do
      client = user.create_new_auth_token['client']
      loaded = User.find(user.id)
      User.find(user.id).update!(tokens: {})
      expect(loaded.tokens).to have_key(client)
      expect(Toybaco::Security::ApplicationMfaSession.attach_proof!(loaded, client)).to be(false)
      expect(user.reload.tokens).to be_empty
    end

    it 'gives proof to a device that is still signed in' do
      client = user.create_new_auth_token['client']
      freeze_time do
        expect(Toybaco::Security::ApplicationMfaSession.attach_proof!(User.find(user.id), client)).to be(true)
        expect(user.reload.tokens[client]).to include('toybaco_mfa_at' => Time.current.to_i,
                                                      'toybaco_mfa_proof' => Toybaco::Security::ApplicationMfaSession.fingerprint(user))
      end
    end

    it 'keeps no device when MFA activation also changes the password' do
      client = user.create_new_auth_token['client']
      user.reload.toybaco_kept_client = client
      user.update!(otp_required_for_login: true, password: 'Password2!')
      expect(user.reload.tokens).to be_empty
    end
  end

  context 'when the user is an unenrolled super admin' do
    let(:user) { create(:super_admin) }

    it 'does not issue a full login before enrollment' do
      login
      expect(response).to have_http_status(:partial_content)
      expect(response.parsed_body).to include('mfa_enrollment_required' => true, 'enrollment_path' => '/toybaco/mfa-enrollment')
      expect(user.reload.tokens).to be_empty
      expect(cookies['cw_d_session_info']).to be_blank
      get '/api/v1/profile', headers: headers
      expect(response).to have_http_status(:unauthorized)
    end

    it 'does not grant enrollment from an incorrect password' do
      login(password: 'incorrect')
      expect(response).to have_http_status(:unauthorized)
      get '/toybaco/mfa-enrollment'
      expect(response).to redirect_to('/app/login')
    end

    # One protocol trace verifies no credential is issued before the actual OTP.
    it 'allows the verified primary session to reach only enrollment until OTP succeeds' do # rubocop:disable RSpec/MultipleExpectations
      login
      get '/toybaco/mfa-enrollment'
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('2段階認証を設定してください')
      expect(response.body).not_to include('data-uri=')
      post '/toybaco/mfa-enrollment', headers: headers.merge('X-CSRF-Token' => csrf)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-uri=')
      expect(user.reload.mfa_enabled?).to be(false)
      expect(user.tokens).to be_empty
      post '/toybaco/mfa-enrollment/verify', params: { otp_code: user.current_otp }, headers: headers.merge('X-CSRF-Token' => csrf)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('バックアップコード')
      expect(user.reload.mfa_enabled?).to be(true)
      get '/api/v1/profile', headers: headers
      expect(response).to have_http_status(:ok)
    end

    it 'expires enrollment on password change and after five minutes' do
      login
      user.update!(password: 'ChangedPassword1!')
      get '/toybaco/mfa-enrollment'
      expect(response).to redirect_to('/app/login')
      login(password: 'ChangedPassword1!')
      travel 5.minutes do
        get '/toybaco/mfa-enrollment'
        expect(response).to redirect_to('/app/login')
      end
    end

    it 'refuses enrollment changes without CSRF and from a sibling origin' do
      login
      post '/toybaco/mfa-enrollment', headers: headers
      expect(response).to have_http_status(:forbidden)
      post '/toybaco/mfa-enrollment', headers: headers.merge('X-CSRF-Token' => csrf, 'Origin' => 'https://sibling.test')
      expect(response).to have_http_status(:forbidden)
      expect(user.reload.otp_secret).to be_nil
    end

    # A no-referrer page makes the browser post its forms with `Origin: null`, which enrollment rejects.
    it 'serves enrollment under a same-origin referrer policy so its form posts keep their origin' do
      login
      get '/toybaco/mfa-enrollment'
      expect(response.headers['Referrer-Policy']).to eq('same-origin')
      expect(response.body).to include('<meta name="referrer" content="same-origin">')
      expect(response.body).not_to include('no-referrer')
      post '/toybaco/mfa-enrollment', headers: headers.merge('X-CSRF-Token' => csrf)
      expect(response).to have_http_status(:ok)
      expect(response.headers['Referrer-Policy']).to eq('same-origin')
    end

    it 'limits bad enrollment codes without enabling MFA or issuing a session' do
      login
      post '/toybaco/mfa-enrollment', headers: headers.merge('X-CSRF-Token' => csrf)
      10.times do
        post '/toybaco/mfa-enrollment/verify', params: { otp_code: 'not-an-otp' }, headers: headers.merge('X-CSRF-Token' => csrf)
        expect(response).to have_http_status(:unprocessable_entity)
      end
      post '/toybaco/mfa-enrollment/verify', params: { otp_code: user.reload.current_otp }, headers: headers.merge('X-CSRF-Token' => csrf)
      expect(response).to have_http_status(:too_many_requests)
      expect(user.reload.mfa_enabled?).to be(false)
      expect(user.tokens).to be_empty
    end
  end
end
