# frozen_string_literal: true

require 'rails_helper'
require 'io/wait'
require Rails.root.join('bin/toybaco-smtp-tls-probe.rb').to_s

# infra/terraform/ecs.tf の app_environment(rails・sidekiq・migrate 共通)の SMTP 値を、固定 upstream の
# config/initializers/mailer.rb の本文にそのまま通し、ActionMailer の設定と mail が組む Net::SMTP の形を固定する。
# 本物の ENV と Rails.application は書き換えず、Rails と ENV だけを差し替えた sandbox で initializer を評価する。
RSpec.describe ToybacoSmtpTlsProbe do
  let(:upstream_initializer) { Rails.root.join('config/initializers/mailer.rb') }
  let(:mailer_double) { Struct.new(:delivery_method, :smtp_settings, :delivery_methods) }

  def terraform_env(domain, overrides = {})
    {
      'SMTP_ADDRESS' => 'email-smtp.ap-northeast-1.amazonaws.com', 'SMTP_PORT' => '465', 'SMTP_DOMAIN' => domain,
      'SMTP_AUTHENTICATION' => 'login', 'SMTP_TLS' => 'true', 'SMTP_ENABLE_STARTTLS_AUTO' => 'false',
      'SMTP_OPENSSL_VERIFY_MODE' => 'peer', 'SMTP_USERNAME' => 'spec-smtp-user', 'SMTP_PASSWORD' => 'spec-smtp-password'
    }.merge(overrides).compact
  end

  # 旧設定(587 + STARTTLS auto)。比較対象としてだけ使う。
  def previous_env(domain)
    terraform_env(domain, 'SMTP_PORT' => '587', 'SMTP_TLS' => nil, 'SMTP_ENABLE_STARTTLS_AUTO' => 'true',
                          'SMTP_OPENSSL_VERIFY_MODE' => nil)
  end

  # initializer が触る config(action_mailer / action_mailbox)だけを持つ Rails.application の代役。
  def sandbox_rails(config, rails_env)
    application = Object.new
    application.define_singleton_method(:config) { config }
    application.define_singleton_method(:configure) { |&block| instance_eval(&block) }
    Module.new.tap do |rails|
      rails.define_singleton_method(:application) { application }
      rails.define_singleton_method(:env) { ActiveSupport::EnvironmentInquirer.new(rails_env) }
    end
  end

  def mailer_config_for(env, rails_env: 'production')
    config = ActiveSupport::OrderedOptions.new
    config.action_mailer = ActiveSupport::OrderedOptions.new
    config.action_mailbox = ActiveSupport::OrderedOptions.new
    config.action_mailbox.ses = ActiveSupport::OrderedOptions.new
    sandbox = Module.new
    sandbox.const_set(:Rails, sandbox_rails(config, rails_env))
    sandbox.const_set(:ENV, env.dup.freeze)
    sandbox.module_eval(upstream_initializer.read, upstream_initializer.to_s, 1)
    config.action_mailer
  end

  # actionmailer 7.2 の railtie は、config/application.rb の load_defaults 7.0 が置く smtp_timeout(5)を
  # initializer の hash へ ||= で足してから ActionMailer::Base.smtp_settings にする。その段まで再現する。
  def booted_smtp_settings(env, rails_env: 'production')
    settings = mailer_config_for(env, rails_env: rails_env).smtp_settings
    settings.merge(open_timeout: settings[:open_timeout] || 5, read_timeout: settings[:read_timeout] || 5)
  end

  def mailer_for(env)
    mailer_double.new(mailer_config_for(env).delivery_method, booted_smtp_settings(env), { smtp: Mail::SMTP })
  end

  def check(env, environment: 'staging', deployment_environment: environment)
    described_class.check(environment: environment, deployment_environment: deployment_environment, mailer: mailer_for(env))
  end

  # 平文の SMTP を話す相手として、受け取った bytes を received へ溜める。AUTH を見たら止める。
  def serve_plain_smtp(socket, received, ehlo_reply)
    socket.write("220 spec.invalid ESMTP\r\n")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break if remaining <= 0 || !socket.wait_readable(remaining)

      chunk = socket.readpartial(4096)
      received << chunk
      socket.write(ehlo_reply) if chunk.start_with?('EHLO')
      break socket.write("535 spec stop\r\n") if chunk.start_with?('AUTH')
    end
  rescue IOError, SystemCallError
    nil
  end

  # 1 接続だけ受ける loopback の偽 SMTP server。client が送った bytes を返す。
  def capture_smtp_client(ehlo_reply:)
    server = TCPServer.new('127.0.0.1', 0)
    received = +''
    thread = Thread.new do
      socket = server.accept
      serve_plain_smtp(socket, received, ehlo_reply)
    ensure
      socket&.close
    end
    yield server.addr[1]
    thread.join(15)
    received
  ensure
    thread&.kill
    server&.close
  end

  def deliver_to(port, env)
    settings = mailer_config_for(env).smtp_settings.merge(address: '127.0.0.1', port: port, open_timeout: 5, read_timeout: 5)
    message = Mail.new(from: 'no-reply@staging.toybaco.jp', to: 'spec@example.invalid', subject: 'spec', body: 'spec')
    Mail::SMTP.new(settings).deliver!(message)
  end

  it '固定 upstream の mailer initializer の本文を前提にする(変わったら env と TLS の対応を見直す)' do
    expect(Digest::SHA256.file(upstream_initializer).hexdigest)
      .to eq('b738a1a9cfe7dc36c26134b1c388c8377fadcb3223d6aed6686a7e3853d77e1b')
    expect(ActionMailer::Base.delivery_methods[:smtp]).to eq(Mail::SMTP)
  end

  it 'sandbox の評価は、起動済みの ActionMailer::Base.smtp_settings を同じ ENV から再現する' do
    expect(booted_smtp_settings(ENV.to_h, rails_env: Rails.env)).to eq(ActionMailer::Base.smtp_settings)
  end

  { 'production' => 'toybaco.jp', 'staging' => 'staging.toybaco.jp' }.each do |environment, domain|
    it "#{environment} の terraform 値は implicit TLS・STARTTLS 無し・証明書検証ありの設定になる" do
      report, failures = check(terraform_env(domain), environment: environment)

      expect(mailer_config_for(terraform_env(domain)).delivery_method).to eq(:smtp)
      expect(booted_smtp_settings(terraform_env(domain))).to eq(
        address: 'email-smtp.ap-northeast-1.amazonaws.com', port: '465', authentication: :login, domain: domain,
        user_name: 'spec-smtp-user', password: 'spec-smtp-password', enable_starttls_auto: false,
        openssl_verify_mode: 'peer', tls: true, open_timeout: 5, read_timeout: 5
      )
      expect(failures).to eq([])
      expect(report[:settings]).to eq(described_class.expected_settings(environment))
      expect(report[:transport]).to eq(tls: true, starttls: false, verify_mode: 'peer', verify_hostname: true)
    end
  end

  it 'PASS 行は password と user_name の値を出さない' do
    io = StringIO.new
    expect(described_class.run!(environment: 'production', deployment_environment: 'production',
                                mailer: mailer_for(terraform_env('toybaco.jp')), io: io)).to be(true)
    expect(io.string).to start_with('TOYBACO_SMTP_TLS_PROBE=PASS {')
    expect(io.string).not_to include('spec-smtp-password')
    expect(io.string).not_to include('spec-smtp-user')
    expect(io.string).to include('"user_name":"[set]"')
  end

  it '旧設定(587 + STARTTLS auto)は日和見の STARTTLS として拒む' do
    report, failures = check(previous_env('staging.toybaco.jp'))

    expect(report[:transport]).to include(tls: false, starttls: 'auto')
    expect(failures).to eq(%w[settings transport])
  end

  {
    'TLS を切ると平文になる' => [{ 'SMTP_TLS' => 'false' }, { tls: false, starttls: false, verify_mode: 'unset' }],
    '証明書検証を none にする' => [{ 'SMTP_OPENSSL_VERIFY_MODE' => 'none' }, { tls: true, verify_mode: 'none' }],
    'TLS と STARTTLS auto を同時に指定する' => [{ 'SMTP_ENABLE_STARTTLS_AUTO' => nil }, { invalid: 'ArgumentError' }],
    'port を 587 に戻す' => [{ 'SMTP_PORT' => '587' }, { tls: true, starttls: false }]
  }.each do |label, (overrides, transport)|
    it "#{label}変更は fail-closed にする" do
      report, failures = check(terraform_env('staging.toybaco.jp', overrides))

      expect(report[:transport]).to include(transport)
      expect(failures).to include('settings')
    end
  end

  it '環境の取り違え・未知の環境・password 欠落を拒む' do
    env = terraform_env('staging.toybaco.jp')

    expect(check(env, environment: 'staging', deployment_environment: 'production').last).to eq(%w[environment])
    expect(check(env, environment: 'production', deployment_environment: 'production').last).to eq(%w[settings])
    expect(check(env, environment: '', deployment_environment: '').last).to eq(%w[environment settings])
    expect(check(terraform_env('staging.toybaco.jp', 'SMTP_PASSWORD' => nil)).last).to eq(%w[password])
  end

  it 'delivery_method が smtp でなければ拒む' do
    mailer = mailer_for(terraform_env('staging.toybaco.jp'))
    mailer.delivery_method = :sendmail

    _report, failures = described_class.check(environment: 'staging', deployment_environment: 'staging', mailer: mailer)
    expect(failures).to eq(%w[delivery_method])
  end

  it 'FAIL は exit 1 で止め、秘密を出さない' do
    io = StringIO.new
    expect do
      described_class.run!(environment: 'staging', deployment_environment: 'staging',
                           mailer: mailer_for(previous_env('staging.toybaco.jp')), io: io)
    end.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    expect(io.string).to start_with('TOYBACO_SMTP_TLS_PROBE=FAIL reasons=settings,transport actual=')
    expect(io.string).not_to include('spec-smtp-password')
    expect(io.string).not_to include('spec-smtp-user')
  end

  it 'implicit TLS は平文の SMTP server に対して SMTP の命令を 1 つも平文で送らずに失敗する' do
    received = capture_smtp_client(ehlo_reply: "250-spec.invalid\r\n250 AUTH LOGIN\r\n") do |port|
      expect { deliver_to(port, terraform_env('staging.toybaco.jp')) }.to raise_error(OpenSSL::SSL::SSLError)
    end

    expect(received.bytes.first).to eq(0x16)
    expect(received).not_to include('EHLO', 'AUTH', 'MAIL FROM')
  end

  it '比較: 旧設定は STARTTLS を提示しない server に AUTH を平文で送る' do
    received = capture_smtp_client(ehlo_reply: "250-spec.invalid\r\n250 AUTH LOGIN\r\n") do |port|
      expect { deliver_to(port, previous_env('staging.toybaco.jp')) }.to raise_error(Net::SMTPAuthenticationError)
    end

    expect(received).to include('EHLO staging.toybaco.jp', 'AUTH LOGIN')
  end

  it 'implicit TLS は信頼できない証明書の server との handshake を拒む' do
    key = OpenSSL::PKey::EC.generate('prime256v1')
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = 1
    certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse('/CN=127.0.0.1')
    certificate.public_key = key
    certificate.not_before = Time.current - 60
    certificate.not_after = Time.current + 3600
    certificate.sign(key, OpenSSL::Digest.new('SHA256'))
    context = OpenSSL::SSL::SSLContext.new
    context.cert = certificate
    context.key = key
    tcp_server = TCPServer.new('127.0.0.1', 0)
    server = OpenSSL::SSL::SSLServer.new(tcp_server, context)
    thread = Thread.new do
      server.accept
    rescue OpenSSL::SSL::SSLError, SystemCallError, IOError
      nil
    end

    expect { deliver_to(tcp_server.addr[1], terraform_env('staging.toybaco.jp')) }
      .to raise_error(OpenSSL::SSL::SSLError, /certificate verify failed/)
  ensure
    thread&.join(5)
    thread&.kill
    server&.close
  end
end
