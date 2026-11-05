# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe 'MFA failure budget', type: :request do
  describe 'Dashboard MFA failure budget' do
    let(:user) { create(:user, otp_secret: User.generate_otp_secret, otp_required_for_login: true, otp_backup_codes: %w[FIRST123 SECOND12]) }

    after do
      Redis::Alfred.delete(Toybaco::Security::MfaLoginAttempts.key(user))
    end

    def verify_code(code, owner: user, type: :backup_code)
      # Each attempt uses a new valid challenge; neither the IP nor challenge
      # throttle can stand in for the account-wide budget.
      challenge = Mfa::TokenService.new(user: owner.reload).generate_token
      post '/auth/sign_in', params: { :mfa_token => challenge, type => code }, as: :json,
                            env: { 'REMOTE_ADDR' => "198.51.100.#{SecureRandom.random_number(200) + 1}" }
    end

    def fail_ten_times
      10.times do |index|
        verify_code('invalid-code', type: index.even? ? :otp_code : :backup_code)
        expect(response).to have_http_status(:bad_request)
      end
    end

    it 'rejects the eleventh code before checking or consuming a valid recovery code' do
      fail_ten_times
      expect(Mfa::AuthenticationService).not_to receive(:new)
      verify_code('FIRST123')
      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body.keys).to eq(['error'])
      expect(user.reload.otp_backup_codes).to include('FIRST123')
      expect(user.tokens).to be_empty
    end

    it 'leaves another user able to sign in successfully' do
      fail_ten_times
      other = create(:user, otp_secret: User.generate_otp_secret, otp_required_for_login: true, otp_backup_codes: ['OTHER123'])
      verify_code('OTHER123', owner: other)
      expect(response).to have_http_status(:ok)
      expect(other.reload.tokens).not_to be_empty
    end

    it 'keeps the limit through fourteen minutes and allows a new attempt at fifteen' do
      freeze_time do
        fail_ten_times
        travel 14.minutes
        verify_code('FIRST123')
        expect(response).to have_http_status(:too_many_requests)
        travel 1.minute
        verify_code('FIRST123')
        expect(response).to have_http_status(:ok)
      end
    end

    it 'does not reset the failure budget after a successful sign-in' do
      9.times { verify_code('invalid-code') }
      verify_code('FIRST123')
      expect(response).to have_http_status(:ok)
      verify_code('invalid-code')
      expect(response).to have_http_status(:bad_request)
      verify_code('SECOND12')
      expect(response).to have_http_status(:too_many_requests)
      expect(user.reload.otp_backup_codes).to include('SECOND12')
    end

    it 'expires only old failures instead of refilling a fixed-window budget' do
      freeze_time do
        5.times { verify_code('invalid-code') }
        travel 14.minutes
        5.times { verify_code('invalid-code') }
        travel 1.minute
        5.times do
          verify_code('invalid-code')
          expect(response).to have_http_status(:bad_request)
        end
        verify_code('FIRST123')
        expect(response).to have_http_status(:too_many_requests)
      end
    end

    it 'fails closed when the shared failure store is unavailable' do
      allow(Redis::Alfred).to receive(:zcount).and_raise(Redis::BaseError)
      verify_code('FIRST123')
      expect(response).to have_http_status(:service_unavailable)
      expect(user.reload.tokens).to be_empty
      expect(user.otp_backup_codes).to include('FIRST123')
    end

    it 'does not charge a user for an invalid challenge' do
      expect(Redis::Alfred).not_to receive(:zcount)
      post '/auth/sign_in', params: { mfa_token: 'invalid-challenge', otp_code: 'invalid-code' }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'MFA failure budget while waiting for a user lock' do
    self.use_transactional_tests = false

    let!(:user) { create(:user, otp_secret: User.generate_otp_secret, otp_required_for_login: true, otp_backup_codes: ['FIRST123']) }

    after do
      Redis::Alfred.delete(Toybaco::Security::MfaLoginAttempts.key(user))
      User.find_by(id: user.id)&.destroy!
    end

    it 'rejects a valid code waiting behind the tenth failure from another entry point' do
      worker = nil
      9.times do
        challenge = Mfa::TokenService.new(user: user.reload).generate_token
        post '/auth/sign_in', params: { mfa_token: challenge, otp_code: 'invalid-code' }, as: :json
        expect(response).to have_http_status(:bad_request)
      end

      started = Queue.new
      user.with_lock do
        # A separate instance and DB connection, as used by admin/profile callers.
        # The real PostgreSQL wait proves verification cannot run before this
        # transaction records the tenth failure; no verifier or lock is mocked.
        worker = Thread.new do
          User.connection_pool.with_connection do |connection|
            other = User.find(user.id)
            started << connection.select_value('SELECT pg_backend_pid()').to_i
            begin
              Mfa::AuthenticationService.new(user: other, backup_code: 'FIRST123').authenticate
            rescue Toybaco::Security::MfaLoginAttempts::LimitExceeded
              :limited
            end
          end
        end
        pid = Timeout.timeout(5) { started.pop }
        Timeout.timeout(5) do
          loop do
            break if User.connection.select_value("SELECT pg_backend_pid() = ANY(pg_blocking_pids(#{pid}))")

            sleep 0.01
          end
        end
        expect(Mfa::AuthenticationService.new(user: user, otp_code: 'invalid-code').authenticate).to be(false)
      end

      expect(Timeout.timeout(5) { worker.value }).to eq(:limited)
      expect(user.reload.otp_backup_codes).to eq(['FIRST123'])
      expect(user.tokens).to be_empty
      expect(Redis::Alfred.zcount(Toybaco::Security::MfaLoginAttempts.key(user), '-inf', '+inf')).to eq(10)
    ensure
      worker&.kill if worker&.alive?
      worker&.join
    end
  end

  describe 'MFA failure budget shared by HTTP entry points' do
    let(:user) { create(:super_admin, otp_secret: User.generate_otp_secret, otp_required_for_login: true, otp_backup_codes: %w[FIRST123 SECOND12]) }
    let(:api_headers) { { 'api_access_token' => user.access_token.token } }

    before { allow(Chatwoot).to receive(:mfa_enabled?).and_return(true) }
    after { Redis::Alfred.delete(Toybaco::Security::MfaLoginAttempts.key(user)) }

    def attempt(route, code: 'invalid-code', type: :backup_code)
      # A new IP and challenge on every request; endpoint/IP throttles cannot
      # supply the cross-route guarantee under test.
      env = { 'REMOTE_ADDR' => "198.51.100.#{SecureRandom.random_number(200) + 1}" }
      case route
      when :dashboard
        challenge = Mfa::TokenService.new(user: user.reload).generate_token
        post '/auth/sign_in', params: { :mfa_token => challenge, type => code }, as: :json, env: env
      when :admin
        post '/super_admin/sign_in', params: { super_admin: { :email => user.email, :password => 'Password1!', type => code } }, env: env
      when :backup_codes
        post '/api/v1/profile/mfa/backup_codes', params: { type => code }, headers: api_headers, as: :json, env: env
      when :disable
        delete '/api/v1/profile/mfa', params: { :password => 'Password1!', type => code }, headers: api_headers, as: :json, env: env
      end
    end

    def exhaust(route, count: 10)
      count.times do |index|
        attempt(route, type: index.even? ? :otp_code : :backup_code)
        expect(response.status).to eq({ dashboard: 400, admin: 302, backup_codes: 422, disable: 422 }.fetch(route))
      end
    end

    def expect_no_code_verification
      allow(Mfa::AuthenticationService).to receive(:new).and_wrap_original do |original, **options|
        service = original.call(**options)
        expect(service).not_to receive(:authenticate_with_otp)
        expect(service).not_to receive(:authenticate_with_backup_code)
        service
      end
    end

    all_routes = %i[dashboard admin backup_codes disable].freeze
    success_routes = %i[admin backup_codes].freeze
    budget_routes = %i[dashboard admin backup_codes].freeze
    store_routes = %i[admin backup_codes disable].freeze
    store_operations = %i[zcount zadd].freeze

    %w[allow log].each do |mode|
      context "with personal API access #{mode}" do
        around { |example| with_modified_env(TOYBACO_PERSONAL_API_ACCESS_MODE: mode) { example.run } }

        all_routes.each do |source|
          it "exhausts via #{source} and rejects valid TOTP and recovery codes on every route" do
            exhaust(source)
            original_codes = user.reload.otp_backup_codes.dup
            all_routes.each do |target|
              { otp_code: user.current_otp, backup_code: 'FIRST123' }.each do |type, code|
                attempt(target, code: code, type: type)
                expect(response).to have_http_status(:too_many_requests)
                expect(user.reload.otp_backup_codes).to eq(original_codes)
                expect(user.consumed_timestep).to be_nil
                expect(user.mfa_enabled?).to be(true)
                expect(user.tokens).to be_empty
              end
            end
            get '/super_admin/accounts'
            expect(response).to redirect_to('/super_admin/sign_in')
          end
        end

        success_routes.each do |route|
          it "does not reset nine dashboard failures after success through #{route}" do
            exhaust(:dashboard, count: 9)
            attempt(route, code: 'FIRST123')
            if route == :admin
              expect(response).to redirect_to('/super_admin')
              delete '/super_admin/sign_out'
            else
              expect(response).to have_http_status(:ok)
            end
            exhaust(:backup_codes, count: 1)
            budget_routes.each do |target|
              attempt(target, code: user.reload.current_otp, type: :otp_code)
              expect(response).to have_http_status(:too_many_requests)
            end
          end
        end

        it 'allows a valid code only after the shared window expires, without clearing it early' do
          freeze_time do
            exhaust(:backup_codes)
            travel 14.minutes
            attempt(:admin, code: 'FIRST123')
            expect(response).to have_http_status(:too_many_requests)
            travel 1.minute
            attempt(:admin, code: 'FIRST123')
            expect(response).to redirect_to('/super_admin')
            expect(user.reload.otp_backup_codes).not_to include('FIRST123')
          end
        end

        store_routes.each do |route|
          store_operations.each do |operation|
            it "fails closed on #{route} when the failure store cannot #{operation}" do
              allow(Redis::Alfred).to receive(operation).and_raise(Redis::BaseError)
              attempt(route, code: operation == :zcount ? 'FIRST123' : 'invalid-code')
              expect(response).to have_http_status(:service_unavailable)
              expect(user.reload.otp_backup_codes).to eq(%w[FIRST123 SECOND12])
              expect(user.mfa_enabled?).to be(true)
              expect(user.tokens).to be_empty
            end
          end
        end

        all_routes.product(%i[otp_code backup_code], %i[incorrect correct]).each do |route, type, validity|
          it "rejects #{validity} #{type} on #{route} before verification when reads work but reservation writes fail" do
            code = type == :otp_code ? user.current_otp : 'FIRST123'
            code = 'invalid-code' if validity == :incorrect
            original = user.reload.attributes.slice('otp_secret', 'otp_required_for_login', 'otp_backup_codes', 'consumed_timestep', 'tokens')
            allow(Redis::Alfred).to receive(:zcount).and_call_original
            expect(Redis::Alfred).to receive(:zadd).and_raise(Redis::BaseError)
            expect_no_code_verification

            attempt(route, code: code, type: type)

            expect(response).to have_http_status(:service_unavailable)
            expect(response.body).not_to include('backup_codes')
            expect(response.headers['access-token']).to be_nil
            expect(user.reload.attributes.slice(*original.keys)).to eq(original)
            expect(Redis::Alfred).to have_received(:zcount).at_least(:once)
            get '/super_admin/accounts'
            expect(response).to redirect_to('/super_admin/sign_in')
          end
        end
      end
    end
  end
end
