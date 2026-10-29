# frozen_string_literal: true

require 'rails_helper'

# A one-time link or token must yield one session even when two requests carry it at the same moment.
RSpec.describe 'Single-use verifiers under concurrent use', type: :request do
  describe 'confirmation link' do
    # The competing request needs its own committed transaction and database connection.
    self.use_transactional_tests = false

    let!(:user) { create(:user, skip_confirmation: false) }

    after { User.find_by(id: user.id)&.destroy! }

    def lock_waiter?(connection)
      connection.select_value(<<~SQL.squish).to_i.positive?
        SELECT count(*) FROM pg_stat_activity
        WHERE datname = current_database() AND pid <> pg_backend_pid() AND wait_event_type = 'Lock'
      SQL
    end

    # Plays a competing request: holds the user's row, waits (up to five seconds) until this request is waiting for
    # a lock, then writes what the competing request writes (confirmation by default) and commits.
    def competing_request(changes = { confirmed_at: Time.current })
      locked = Queue.new
      thread = Thread.new do
        User.connection_pool.with_connection do |connection|
          User.transaction do
            User.lock.find(user.id)
            locked << true
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
            sleep 0.05 until lock_waiter?(connection) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            User.where(id: user.id).update_all(changes) # rubocop:disable Rails/SkipsModelValidations
          end
        end
      end
      locked.pop
      thread
    end

    it 'gives the second simultaneous request "Already confirmed" and no session' do
      token = user.confirmation_token
      expect(user.confirmed?).to be(false)

      first = competing_request
      post '/auth/confirmation', params: { confirmation_token: token }, as: :json
      first.join

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['message']).to eq('Already confirmed')
      expect(response.headers['access-token']).to be_nil
      expect(user.reload.tokens).to be_blank
    end

    it 'still confirms once and issues the session when no other request holds the link' do
      post '/auth/confirmation', params: { confirmation_token: user.confirmation_token }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.headers['access-token']).to be_present
      expect(user.reload.confirmed?).to be(true)
      post '/auth/confirmation', params: { confirmation_token: user.confirmation_token }, as: :json
      expect(response.parsed_body['message']).to eq('Already confirmed')
    end

    # Devise's resend replaces an expired token and its sent time. A request holding the old link that waited for the
    # row must not confirm the refreshed row (nor a newly pending email).
    it 'treats a link that a concurrent resend replaced as unknown and issues no session' do
      token = user.confirmation_token
      user.update_columns(confirmation_sent_at: 25.hours.ago) # rubocop:disable Rails/SkipsModelValidations

      resend = competing_request(confirmation_token: SecureRandom.hex(10), confirmation_sent_at: Time.current)
      post '/auth/confirmation', params: { confirmation_token: token }, as: :json
      resend.join

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['message']).to eq('Invalid token')
      expect(response.headers['access-token']).to be_nil
      expect(user.reload.confirmed?).to be(false)
    end

    it 'rejects blank and non-string tokens without confirming or issuing a session' do
      token = user.confirmation_token
      [[{ confirmation_token: [token] }, :json], [{ confirmation_token: [token] }, nil],
       [{ confirmation_token: { value: token } }, :json], [{ confirmation_token: '' }, :json]].each do |params, format|
        post '/auth/confirmation', params: params, as: format

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['message']).to eq('Invalid token')
        expect(response.headers['access-token']).to be_nil
      end
      expect(user.reload.confirmed?).to be(false)
    end
  end

  describe 'SSO token' do
    let(:user) { create(:user) }
    let(:token) { user.generate_sso_auth_token }

    # Plays a second request that removes the token right after this request has validated it.
    def consume_after_validation
      key = user.send(:sso_token_key, token)
      allow(Redis::Alfred).to receive(:get).and_wrap_original do |original, requested|
        original.call(requested).tap { Redis::Alfred.delete(key) if requested == key }
      end
    end

    def sso_sign_in(extra = {}, headers: {}, sso_token: token)
      post '/auth/sign_in', params: { email: user.email, sso_auth_token: sso_token }.merge(extra), headers: headers, as: :json
    end

    it 'issues no session when another request used the token after this one validated it' do
      consume_after_validation
      sso_sign_in

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers['access-token']).to be_nil
      expect(user.reload.tokens).to be_blank
    end

    it 'issues no MFA challenge when another request used the token first' do
      user.update!(otp_secret: User.generate_otp_secret, otp_required_for_login: true, otp_backup_codes: ['ABCDEF12'])
      consume_after_validation
      sso_sign_in

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body['mfa_token']).to be_nil
    end

    it 'still signs in once with an unused token and rejects its reuse' do
      sso_sign_in
      expect(response).to have_http_status(:ok)
      expect(response.headers['access-token']).to be_present

      sso_sign_in
      expect(response).to have_http_status(:unauthorized)
    end

    # The winner has signed in (its device and session row exist). The request that lost the same token arrives later
    # carrying the session picker's revoke_all_sessions; it must not log out the winner before failing.
    it 'leaves every device and session row when a request that lost the token asked to revoke sessions' do
      sso_sign_in(sso_token: user.generate_sso_auth_token)
      expect(response).to have_http_status(:ok)
      devices = user.reload.tokens.keys
      sessions = user.user_sessions.pluck(:id)

      consume_after_validation
      sso_sign_in({ revoke_all_sessions: true })

      expect(response).to have_http_status(:unauthorized)
      expect([devices.size, sessions.size]).to eq([1, 1])
      expect(user.reload.tokens.keys).to eq(devices)
      expect(user.user_sessions.pluck(:id)).to eq(sessions)
    end

    it 'evicts no device when a request that lost the token is at the session limit' do
      sso_sign_in(sso_token: user.generate_sso_auth_token)
      devices = user.reload.tokens.keys
      sessions = user.user_sessions.pluck(:id)

      consume_after_validation
      with_modified_env(MAX_USER_SESSIONS: '1') { sso_sign_in }

      expect(response).to have_http_status(:unauthorized)
      expect(user.reload.tokens.keys).to eq(devices)
      expect(user.user_sessions.pluck(:id)).to eq(sessions)
    end

    it 'keeps the token for a retry when the sign-in only shows the session picker' do
      sso_sign_in(sso_token: user.generate_sso_auth_token)
      browser = { 'User-Agent' => 'Mozilla/5.0' }
      with_modified_env(MAX_USER_SESSIONS: '1') do
        sso_sign_in(headers: browser)
        expect(response).to have_http_status(:conflict)
        expect(user.valid_sso_auth_token?(token)).to be(true)

        sso_sign_in({ revoke_all_sessions: true }, headers: browser)
      end

      expect(response).to have_http_status(:ok)
      expect(user.valid_sso_auth_token?(token)).to be(false)
      expect(user.reload.tokens.size).to eq(1)
    end

    # The same browser sent the token twice and both requests passed the check before the winner removed it. The
    # loser left before the winner's response (so without the login cookie) and answers after it.
    it 'leaves the winning login cookie in the browser when the duplicate that lost the token answers later' do
      host! 'chatwoot.test'
      https!
      browser = { 'Origin' => 'https://chatwoot.test', 'X-Toybaco-Browser' => '1', 'Sec-Fetch-Site' => 'same-origin' }
      get '/toybaco/browser-session', headers: browser
      browser = browser.merge('X-CSRF-Token' => response.parsed_body.fetch('csrf_token'))
      key = user.send(:sso_token_key, token)

      sso_sign_in(headers: browser)
      expect(response).to have_http_status(:ok)
      winner_devices = user.reload.tokens.keys
      # The duplicate left the browser before the winner's response set the login cookies. Remove them from the jar
      # (keeping the CSRF session cookie as the browser sent it) instead of rebuilding a Cookie header by hand.
      %w[cw_d_session_info cw_d_authenticated].each { |name| cookies.delete(name) }
      allow(Redis::Alfred).to receive(:get).and_wrap_original do |original, requested|
        requested == key ? 'normal' : original.call(requested)
      end
      sso_sign_in(headers: browser)

      expect(response).to have_http_status(:unauthorized)
      # The browser keeps the winner's login cookies: the losing answer must not expire them.
      expect(response.headers['Set-Cookie'].to_s).not_to include('cw_d_')
      expect(user.reload.tokens.keys).to eq(winner_devices)
    end
  end
end
