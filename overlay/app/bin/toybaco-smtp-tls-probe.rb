# frozen_string_literal: true

require 'json'
require 'openssl'

# Chatwoot のシステムメール(SES SMTP)の TLS 設定を Rails 起動後の値で確かめる read-only probe。
# 標準 deploy は checkout の本文に `ToybacoSmtpTlsProbe.run!` を足し、新しい rails task definition の上で
# `rails runner` に渡す(image の版に依らない)。接続・送信・DB 書き込みはしない。password は出さず、
# user_name は有無だけ出す。期待値と exact 一致しなければ exit 1(fail-closed)。
module ToybacoSmtpTlsProbe
  DOMAINS = { 'production' => 'toybaco.jp', 'staging' => 'staging.toybaco.jp' }.freeze
  TRANSPORT = { tls: true, starttls: false, verify_mode: 'peer', verify_hostname: true }.freeze

  module_function

  # timeout 2 つは Rails の load_defaults 7.0(smtp_timeout = 5)を ActionMailer の railtie が足す値。
  def expected_settings(environment)
    {
      address: 'email-smtp.ap-northeast-1.amazonaws.com', port: '465', domain: DOMAINS.fetch(environment),
      authentication: :login, user_name: '[set]', enable_starttls_auto: false, openssl_verify_mode: 'peer', tls: true,
      open_timeout: 5, read_timeout: 5
    }
  end

  def credential?(value)
    value.is_a?(String) && !value.empty?
  end

  def redact(settings)
    redacted = settings.except(:password)
    redacted[:user_name] = credential?(redacted[:user_name]) ? '[set]' : '[missing]' if redacted.key?(:user_name)
    redacted
  end

  # mail が配信時に作る Net::SMTP を、接続せずに同じ手順で組み立てて読む。
  def transport(settings, smtp_class)
    smtp = smtp_class.new(settings).send(:build_smtp_session)
    context = smtp.instance_variable_get(:@ssl_context_tls)
    modes = { OpenSSL::SSL::VERIFY_PEER => 'peer', OpenSSL::SSL::VERIFY_NONE => 'none' }
    {
      tls: smtp.tls? == true, starttls: smtp.starttls? ? smtp.starttls?.to_s : false,
      verify_mode: context ? modes.fetch(context.verify_mode, context.verify_mode.to_s) : 'unset',
      verify_hostname: context&.verify_hostname == true
    }
  rescue StandardError => e
    { invalid: e.class.name }
  end

  def check(environment:, deployment_environment:, mailer:)
    settings = mailer.smtp_settings.to_h.transform_keys(&:to_sym)
    smtp_class = mailer.delivery_methods[:smtp]
    report = { environment: environment, delivery_method: mailer.delivery_method.to_s, settings: redact(settings),
               transport: transport(settings, smtp_class) }
    known = DOMAINS.key?(environment)
    passed = {
      'environment' => known && environment == deployment_environment,
      'delivery_method' => mailer.delivery_method == :smtp && smtp_class == Mail::SMTP,
      'password' => credential?(settings[:password]),
      'settings' => known && report[:settings] == expected_settings(environment),
      'transport' => report[:transport] == TRANSPORT
    }
    [report, passed.reject { |_name, ok| ok }.keys]
  end

  def run!(environment: ENV.fetch('TOYBACO_SMTP_TLS_PROBE_ENVIRONMENT', ''),
           deployment_environment: ENV.fetch('TOYBACO_DEPLOYMENT_ENVIRONMENT', ''), mailer: ActionMailer::Base, io: $stdout)
    report, failures = check(environment: environment, deployment_environment: deployment_environment, mailer: mailer)
    if failures.empty?
      io.puts("TOYBACO_SMTP_TLS_PROBE=PASS #{JSON.generate(report)}")
      return true
    end

    expected = DOMAINS.key?(environment) ? expected_settings(environment) : nil
    io.puts("TOYBACO_SMTP_TLS_PROBE=FAIL reasons=#{failures.join(',')} actual=#{JSON.generate(report)} " \
            "expected=#{JSON.generate({ settings: expected, transport: TRANSPORT })}")
    exit(1)
  end
end
