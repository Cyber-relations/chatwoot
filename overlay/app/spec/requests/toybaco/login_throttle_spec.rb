# frozen_string_literal: true

require 'rails_helper'

# The dashboard sends both sign-in steps as JSON. Upstream's rules read only form parameters, so the MFA step
# counted as a password attempt and every user's MFA step shared one login/email bucket (empty discriminator).
RSpec.describe 'Dashboard sign-in throttles', type: :request do
  rules = %w[login/ip login/email mfa_login/ip mfa_login/token].freeze

  def fresh_ip
    "2001:db8:#{SecureRandom.hex(2)}:#{SecureRandom.hex(2)}::#{SecureRandom.hex(2)}"
  end

  def sha256(value)
    Digest::SHA256.hexdigest(value)
  end

  describe 'rule discriminators' do
    let(:ip) { fresh_ip }

    define_method(:discriminators) do |env|
      rules.index_with { |name| Rack::Attack.throttles.fetch(name).block.call(Rack::Attack::Request.new(env)) }
    end

    # PATH_INFO is set as given: URI parsing would read //auth//sign_in as a host. env entries override the defaults.
    def sign_in_env(body, path: '/auth/sign_in', **env)
      input = body.is_a?(String) ? body : body.to_json
      defaults = { 'REQUEST_METHOD' => 'POST', 'CONTENT_TYPE' => 'application/json', 'REMOTE_ADDR' => ip, 'PATH_INFO' => path }
      Rack::MockRequest.env_for('/', { input: input }.merge(defaults, env))
    end

    it 'reads a JSON MFA step as an MFA attempt and never as a password attempt' do
      env = sign_in_env({ mfa_token: 'challenge-token', otp_code: '123456' })

      expect(discriminators(env)).to eq('login/ip' => nil, 'login/email' => nil, 'mfa_login/ip' => ip,
                                        'mfa_login/token' => sha256('challenge-token'))
    end

    it 'keys a JSON password step by IP and by the email the controller authenticates' do
      env = sign_in_env({ email: " Agent@Example.Test\t", password: 'wrong' })
      header_env = sign_in_env({ password: 'wrong' }, 'HTTP_EMAIL' => 'agent@example.test')
      both_env = sign_in_env({ email: 'agent@example.test', password: 'wrong' }, 'HTTP_EMAIL' => 'other@example.test')
      false_env = sign_in_env({ email: false, password: 'wrong' }, 'HTTP_EMAIL' => 'agent@example.test')

      expect(discriminators(env)).to eq('login/ip' => ip, 'login/email' => sha256('agent@example.test'),
                                        'mfa_login/ip' => nil, 'mfa_login/token' => nil)
      expect(discriminators(header_env)['login/email']).to eq(sha256('agent@example.test'))
      expect(discriminators(both_env)['login/email']).to eq(sha256('agent@example.test'))
      expect(discriminators(false_env)['login/email']).to eq(sha256('agent@example.test'))
    end

    it 'never returns an empty email discriminator' do
      [{ password: 'wrong' }, { email: '', password: 'wrong' }, { email: " \t", password: 'wrong' },
       { email: ['agent@example.test'], password: 'wrong' }, { email: { value: 'agent@example.test' }, password: 'wrong' }].each do |body|
        result = discriminators(sign_in_env(body))
        expect(result).to include('login/ip' => ip, 'login/email' => nil)
      end
    end

    it 'treats an MFA token in the query string or of another JSON type as the MFA step the controller takes' do
      query = discriminators(sign_in_env({ email: 'agent@example.test', password: 'wrong' }, 'QUERY_STRING' => 'mfa_token=challenge-token'))
      typed = discriminators(sign_in_env({ mfa_token: ['challenge-token'], otp_code: '123456' }))

      expect(query).to eq('login/ip' => nil, 'login/email' => nil, 'mfa_login/ip' => ip, 'mfa_login/token' => sha256('challenge-token'))
      expect(typed).to eq('login/ip' => nil, 'login/email' => nil, 'mfa_login/ip' => ip, 'mfa_login/token' => nil)
    end

    it 'matches every path the router sends to the sign-in action and nothing else' do
      ['/auth/sign_in/', '/auth/sign_in.json', '//auth//sign_in', '/auth/sign_in.json/'].each do |path|
        expect(discriminators(sign_in_env({ password: 'wrong' }, path: path))['login/ip']).to eq(ip)
      end
      expect(discriminators(sign_in_env({ password: 'wrong' }, path: '/auth/sign_in_other')).values).to all(be_nil)
      expect(discriminators(sign_in_env({ password: 'wrong' }, path: '/auth/%ff')).values).to all(be_nil)
      expect(discriminators(sign_in_env('', 'REQUEST_METHOD' => 'GET')).values).to all(be_nil)
    end

    it 'counts an unparsable body as a password attempt by IP without raising' do
      [sign_in_env('{"mfa_token":'), sign_in_env('email=%ff', 'CONTENT_TYPE' => 'application/x-www-form-urlencoded')].each do |env|
        expect(discriminators(env)).to eq('login/ip' => ip, 'login/email' => nil, 'mfa_login/ip' => nil, 'mfa_login/token' => nil)
      end
    end

    it 'keys an MFA challenge by its signed part, whatever the spelling of the signature segment' do
      key = ->(token) { discriminators(sign_in_env({ mfa_token: token, otp_code: '123456' }))['mfa_login/token'] }

      expect(['head.body.sig', "head.body.sig\n", 'head.body.sig=', 'head.body.other'].map(&key).uniq).to eq([sha256('head.body')])
      expect(key.call('head.other.sig')).to eq(sha256('head.other'))
      expect(key.call('...')).to be_nil
    end
  end

  describe 'requests through Rack::Attack' do
    around do |example|
      original = Rack::Attack.enabled
      Rack::Attack.enabled = true
      # One frozen clock keeps every request of an example inside the same throttle period.
      freeze_time { example.run }
    ensure
      Rack::Attack.enabled = original
    end

    def post_sign_in(body, ip, headers: {})
      post '/auth/sign_in', params: body, headers: headers, env: { 'REMOTE_ADDR' => ip }, as: :json
      response.status
    end

    def mfa_step(token, ip)
      post_sign_in({ mfa_token: token, otp_code: '123456' }, ip)
    end

    it 'does not let MFA steps of different users exhaust one shared bucket' do
      statuses = Array.new(11) { mfa_step(SecureRandom.hex(16), fresh_ip) }

      expect(statuses).to all(eq(401))
    end

    it 'limits MFA steps per IP at the MFA limit instead of the password limit' do
      ip = fresh_ip
      statuses = Array.new(11) { mfa_step(SecureRandom.hex(16), ip) }

      expect(statuses).to eq(([401] * 10) + [429])
    end

    it 'limits each MFA challenge to ten attempts across IPs without touching other challenges' do
      token = SecureRandom.hex(16)
      first = Array.new(10) { mfa_step(token, fresh_ip) }

      expect(first).to all(eq(401))
      expect(mfa_step(SecureRandom.hex(16), fresh_ip)).to eq(401)
      expect(mfa_step(token, fresh_ip)).to eq(429)
    end

    it 'still limits password attempts per IP and per normalized email, including the email header' do
      ip = fresh_ip
      per_ip = Array.new(6) { post_sign_in({ email: "#{SecureRandom.hex(6)}@example.test", password: 'wrong' }, ip) }
      email = "#{SecureRandom.hex(6)}@example.test"
      per_email = Array.new(10) { |index| post_sign_in({ email: index.even? ? " #{email.upcase} " : email, password: 'wrong' }, fresh_ip) }

      expect(per_ip).to eq(([401] * 5) + [429])
      expect(per_email).to all(eq(401))
      expect(post_sign_in({ password: 'wrong' }, fresh_ip, headers: { 'email' => email })).to eq(429)
    end

    it 'does not put password attempts without an email into one shared bucket' do
      statuses = Array.new(11) { post_sign_in({ password: 'wrong' }, fresh_ip) }

      expect(statuses).to all(eq(401))
    end

    it 'keeps a real two-step sign-in working while the rules are enabled' do
      user = create(:user, otp_secret: User.generate_otp_secret, otp_required_for_login: true, otp_backup_codes: ['ABCDEF12'])
      ip = fresh_ip

      expect(post_sign_in({ email: user.email, password: 'Password1!' }, ip)).to eq(206)
      expect(post_sign_in({ mfa_token: response.parsed_body.fetch('mfa_token'), backup_code: 'ABCDEF12' }, ip)).to eq(200)
    end

    # jwt 2.10.3 accepts a challenge with whitespace after the signature; every spelling below is the same challenge.
    it 'limits equivalent spellings of one real challenge to ten attempts across IPs' do
      user = create(:user, otp_secret: User.generate_otp_secret, otp_required_for_login: true)
      expect(post_sign_in({ email: user.email, password: 'Password1!' }, fresh_ip)).to eq(206)
      challenge = response.parsed_body.fetch('mfa_token')
      spellings = Array.new(11) { |index| challenge + ("\n" * (index + 1)) }
      window = (-1..1).map { |offset| user.otp.at(Time.current + (offset * 30)) }
      wrong = %w[000000 111111 222222 333333].find { |candidate| window.exclude?(candidate) }

      expect(spellings.map { |spelling| Mfa::TokenService.new(token: spelling).verify_token }).to all(eq(user))
      statuses = spellings.map { |spelling| post_sign_in({ mfa_token: spelling, otp_code: wrong }, fresh_ip) }
      expect(statuses).to eq(([400] * 10) + [429])
    end

    it 'counts a false email that the controller replaces with the email header under that address' do
      email = "#{SecureRandom.hex(6)}@example.test"
      first = Array.new(10) { post_sign_in({ email: email, password: 'wrong' }, fresh_ip) }

      expect(first).to all(eq(401))
      expect(post_sign_in({ email: false, password: 'wrong' }, fresh_ip, headers: { 'email' => email })).to eq(429)
    end
  end
end
