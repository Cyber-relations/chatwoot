# frozen_string_literal: true

require 'digest'
require 'json'
require 'mail'
require 'net/smtp'
require 'openssl'
require 'time'
require 'timeout'
require_relative 'toybaco-smtp-tls-probe'

# Explicit, one-message proof using the application's registered SMTP transport.
# Loading this file sends nothing. The release owner supplies a separately reviewed
# raw plan pin and current deployment context; the plan cannot authorize itself.
# SMTP acceptance is deliberately NOT mailbox delivery or a CASA result.
module ToybacoSmtpDeliveryProof
  class Rejected < StandardError; end

  KEYS = %w[action environment recipient_role recipient sender run_marker source_sha image_digest issued_at expires_at].sort.freeze
  HEX = /\A[0-9a-f]{64}\z/
  SOURCE = /\A[0-9a-f]{40}\z/
  IMAGE = /\Asha256:[0-9a-f]{64}\z/
  MARKER = /\Asmtp-proof-[0-9a-f]{32}\z/
  ADDRESS = /\A[A-Za-z0-9.!\#$%&'*+\/=^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\z/
  MAX_BYTES = 4096
  MAX_AGE = 600
  MailerSnapshot = Struct.new(:delivery_method, :smtp_settings, :delivery_methods)

  module_function

  def reject!(condition, reason)
    raise Rejected, reason unless condition
  end

  def address?(value)
    value.is_a?(String) && value.bytesize <= 254 && ADDRESS.match?(value) && Mail::Address.new(value).address == value
  rescue StandardError
    false
  end

  def plan(raw, env, now, mailer)
    pin = env.fetch('TOYBACO_SMTP_PROOF_PLAN_SHA256', '')
    reject!(raw.is_a?(String) && raw.bytesize.between?(1, MAX_BYTES) && raw.valid_encoding?, 'plan')
    reject!(HEX.match?(pin) && OpenSSL.fixed_length_secure_compare(Digest::SHA256.hexdigest(raw), pin), 'pin')
    # Reject duplicates in the parser, before it coalesces members into an object.
    # object_class setters can see only the final unique members.
    value = JSON.parse(raw, allow_duplicate_key: false)
    reject!(value.is_a?(Hash) && value.keys.sort == KEYS && value.values.all? { |v| v.is_a?(String) }, 'plan')
    reject!(value['action'] == 'send_one_owned_fixture' && value['recipient_role'] == 'owned_release_fixture', 'action')
    environment = value['environment']
    reject!(ToybacoSmtpTlsProbe::DOMAINS.key?(environment) &&
      environment == env.fetch('TOYBACO_DEPLOYMENT_ENVIRONMENT', ''), 'environment')
    reject!(SOURCE.match?(value['source_sha']) && value['source_sha'] == env.fetch('TOYBACO_SMTP_PROOF_SOURCE_SHA', '') &&
      IMAGE.match?(value['image_digest']) && value['image_digest'] == env.fetch('TOYBACO_SMTP_PROOF_IMAGE_DIGEST', ''), 'context')
    reject!(MARKER.match?(value['run_marker']), 'marker')
    reject!(address?(value['recipient']) && address?(value['sender']), 'address')
    configured_sender = Mail::Address.new(env.fetch('MAILER_SENDER_EMAIL', '')).address
    reject!(configured_sender == value['sender'] && value['sender'].split('@').last == ToybacoSmtpTlsProbe::DOMAINS.fetch(environment), 'sender')
    issued = Time.iso8601(value['issued_at'])
    expires = Time.iso8601(value['expires_at'])
    reject!(issued <= now && issued >= now - MAX_AGE && expires > now && expires <= issued + MAX_AGE, 'expiry')
    _report, failures = ToybacoSmtpTlsProbe.check(environment: environment, deployment_environment: environment, mailer: mailer)
    reject!(failures.empty?, 'tls')
    value
  rescue JSON::ParserError, ArgumentError, TypeError
    raise Rejected, 'plan'
  end

  def run!(input: $stdin, io: $stdout, env: ENV, now: Time.now.utc, mailer: ActionMailer::Base, attempt_directory: '/tmp')
    attempted = false
    raw = input.read(MAX_BYTES + 1)
    raw = raw.dup.force_encoding(Encoding::UTF_8) if raw.is_a?(String)
    settings = mailer.smtp_settings.to_h.transform_keys(&:to_sym).transform_values do |value|
      value.is_a?(String) ? value.dup.freeze : value
    end.freeze
    snapshot = MailerSnapshot.new(mailer.delivery_method, settings, mailer.delivery_methods.dup.freeze).freeze
    approved = plan(raw, env, now, snapshot)
    pin = Digest::SHA256.hexdigest(raw)
    # EXCL refuses an existing file or symlink. Keep the journal on all outcomes;
    # another task must consult the owner's durable receipt, never retry blindly.
    begin
      File.open(File.join(attempt_directory, "toybaco-smtp-#{pin}.attempted"), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(plan_sha256: pin, attempted_at: now.utc.iso8601, attempt: 1))
        file.flush
        file.fsync
      end
    rescue Errno::EEXIST
      raise Rejected, 'already_attempted'
    end

    marker = approved.fetch('run_marker')
    message = Mail.new
    message.from = approved.fetch('sender')
    message.to = approved.fetch('recipient')
    message.subject = "Toybaco owned release SMTP check #{marker}"
    message.body = "One owned release fixture message. Reference: #{marker}. No customer data."
    message.message_id = "#{marker}@#{ToybacoSmtpTlsProbe::DOMAINS.fetch(approved.fetch('environment'))}"
    message.date = now
    attempted = true
    response = Timeout.timeout(45) { Mail::SMTP.new(settings.merge(return_response: true)).deliver!(message) }
    unless response.is_a?(Net::SMTP::Response) && response.status == '250' && response.success?
      io.puts('TOYBACO_SMTP_DELIVERY=NO_GO attempted=1 reason=delivery_uncertain mailbox=NOT_OBSERVED')
      return false
    end

    io.puts("TOYBACO_SMTP_DELIVERY=ACCEPTED attempted=1 response_code=250 mailbox=NOT_OBSERVED " \
      "plan_sha256=#{pin} recipient_sha256=#{Digest::SHA256.hexdigest(approved.fetch('recipient'))} " \
      "message_id_sha256=#{Digest::SHA256.hexdigest(message.message_id)} marker_sha256=#{Digest::SHA256.hexdigest(marker)}")
    true
  rescue Rejected => error
    io.puts("TOYBACO_SMTP_DELIVERY=NO_GO attempted=#{attempted ? 1 : 0} reason=#{error.message} mailbox=NOT_OBSERVED")
    false
  rescue StandardError
    # SMTP error text can contain addresses, credentials or remote free text.
    # A failed/ambiguous attempt stays journalled and is never automatically retried.
    io.puts("TOYBACO_SMTP_DELIVERY=NO_GO attempted=#{attempted ? 1 : 0} reason=#{attempted ? 'delivery_uncertain' : 'preflight'} mailbox=NOT_OBSERVED")
    false
  ensure
    raw.clear if raw.is_a?(String)
  end
end
