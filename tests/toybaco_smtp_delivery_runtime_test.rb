# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require Rails.root.join('bin/toybaco-smtp-delivery-proof.rb').to_s

class ToybacoSmtpDeliveryRuntimeTest < Minitest::Test
  Mailer = Struct.new(:delivery_method, :smtp_settings, :delivery_methods)

  def setup
    @now = Time.utc(2026, 10, 19, 0, 0, 0)
    @directory = Dir.mktmpdir('toybaco-smtp-native-')
    @settings = ToybacoSmtpTlsProbe.expected_settings('staging').merge(user_name: 'native-user', password: 'native-only-value')
    @mailer = Mailer.new(:smtp, @settings, { smtp: Mail::SMTP })
    @env = { 'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'staging', 'MAILER_SENDER_EMAIL' => 'Toybaco <no-reply@staging.toybaco.jp>',
      'TOYBACO_SMTP_PROOF_SOURCE_SHA' => 'a' * 40, 'TOYBACO_SMTP_PROOF_IMAGE_DIGEST' => "sha256:#{'b' * 64}" }
    @plan = { 'action' => 'send_one_owned_fixture', 'environment' => 'staging', 'recipient_role' => 'owned_release_fixture',
      'recipient' => 'owned-release@example.invalid', 'sender' => 'no-reply@staging.toybaco.jp',
      'run_marker' => "smtp-proof-#{'c' * 32}", 'source_sha' => 'a' * 40, 'image_digest' => "sha256:#{'b' * 64}",
      'issued_at' => @now.iso8601, 'expires_at' => (@now + 300).iso8601 }
    @calls = []
    @response = Net::SMTP::Response.parse('250 accepted-native')
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
  end

  # Real Mail::SMTP and Mail::SMTPConnection construct and encode the envelope.
  # Only their Net::SMTP session is an owned in-memory peer: no network/send.
  def run_proof(plan: @plan, env: @env, raw: nil, pin: nil, mailer: @mailer)
    raw ||= JSON.generate(plan)
    effective = env.merge('TOYBACO_SMTP_PROOF_PLAN_SHA256' => pin || Digest::SHA256.hexdigest(raw))
    io = StringIO.new
    original = Mail::SMTP.method(:new)
    factory = lambda do |settings|
      transport = original.call(settings)
      if settings[:return_response]
        calls, response, failure = @calls, @response, @failure
        peer = Object.new
        peer.define_singleton_method(:start) { |*args, &block| block.call(self) }
        peer.define_singleton_method(:sendmail) do |encoded, sender, recipients|
          calls << { encoded: encoded, sender: sender, recipients: recipients }
          raise failure if failure

          response
        end
        transport.define_singleton_method(:build_smtp_session) { peer }
      end
      transport
    end
    result = Mail::SMTP.stub(:new, factory) do
      ToybacoSmtpDeliveryProof.run!(input: StringIO.new(raw), io: io, env: effective, now: @now,
        mailer: mailer, attempt_directory: @directory)
    end
    [result, io.string]
  end

  def rejects_without_attempt(label: 'invalid_plan', **args)
    before = @calls.length
    ok, output = run_proof(**args)
    refute ok, label
    assert_includes output, 'NO_GO attempted=0'
    assert_equal before, @calls.length
    assert_empty Dir.children(@directory)
  end

  def test_exact_reviewed_plan_uses_real_mail_envelope_once_and_returns_only_hashes
    ok, output = run_proof
    assert ok
    assert_equal 1, @calls.length
    sent = @calls.fetch(0)
    assert_equal ['owned-release@example.invalid'], sent[:recipients]
    assert_equal @plan['sender'], sent[:sender]
    decoded = Mail.read_from_string(sent[:encoded])
    assert_equal [@plan['recipient']], decoded.to
    assert_nil decoded.cc
    assert_nil decoded.bcc
    assert_empty decoded.attachments
    assert_includes decoded.body.decoded, @plan['run_marker']
    assert_includes output, 'ACCEPTED attempted=1 response_code=250 mailbox=NOT_OBSERVED'
    assert_includes output, "message_id_sha256=#{Digest::SHA256.hexdigest(decoded.message_id)}"
    [@plan['recipient'], @plan['sender'], @plan['run_marker'], 'native-user', 'native-only-value', 'accepted-native'].each do |private_value|
      refute_includes output, private_value
    end
    assert_equal 1, Dir.children(@directory).length
    assert_equal 0o600, File.stat(File.join(@directory, Dir.children(@directory).first)).mode & 0o777
    assert_equal false, @settings.key?(:return_response), 'app global settings are unchanged'
  end

  def test_pin_binds_raw_bytes_and_rejects_missing_wrong_or_uppercase_pins
    raw = JSON.generate(@plan)
    ['', 'd' * 64, Digest::SHA256.hexdigest(raw).upcase].each { |pin| rejects_without_attempt(raw: raw, pin: pin) }
    rejects_without_attempt(raw: raw + ' ', pin: Digest::SHA256.hexdigest(raw))
  end

  def test_unknown_duplicate_missing_or_nonstring_plan_fields_never_send
    rejects_without_attempt(label: 'unknown_key', plan: @plan.merge('cc' => 'other@example.invalid'))
    rejects_without_attempt(label: 'missing_key', plan: @plan.reject { |key, _| key == 'action' })
    rejects_without_attempt(label: 'nonstring_value', plan: @plan.merge('recipient' => ['owned-release@example.invalid']))
    raw = JSON.generate(@plan).sub('{', '{"action":"different",')
    rejects_without_attempt(label: 'duplicate_action', raw: raw)
    rejects_without_attempt(label: 'duplicate_recipient', raw: JSON.generate(@plan).sub('{', '{"recipient":"other@example.invalid",'))
    rejects_without_attempt(label: 'escaped_duplicate_recipient', raw: JSON.generate(@plan).sub('{', '{"re\\u0063ipient":"other@example.invalid",'))
    rejects_without_attempt(label: 'oversize', raw: 'x' * (ToybacoSmtpDeliveryProof::MAX_BYTES + 1))
    assert_match(/\A[0-9]+(?:\.[0-9]+)+\z/, JSON::VERSION)
    puts "TOYBACO_SMTP_JSON_BOUNDARY=PASS version=#{JSON::VERSION} duplicate_cases=3"
  end

  def test_action_role_and_context_are_not_inferred_from_fixture_membership
    [{ 'action' => 'send' }, { 'recipient_role' => 'customer' }, { 'environment' => 'production' },
      { 'source_sha' => 'd' * 40 }, { 'image_digest' => "sha256:#{'d' * 64}" }].each do |change|
      rejects_without_attempt(plan: @plan.merge(change))
    end
  end

  def test_single_address_and_configured_sender_guard_rejects_header_injection
    ["owned-release@example.invalid\r\nBcc: other@example.invalid", 'one@example.invalid,two@example.invalid',
      'Display <owned-release@example.invalid>'].each { |recipient| rejects_without_attempt(plan: @plan.merge('recipient' => recipient)) }
    rejects_without_attempt(plan: @plan.merge('sender' => 'other@staging.toybaco.jp'))
    rejects_without_attempt(plan: @plan.merge('run_marker' => "smtp-proof-#{'c' * 32}\r\nBcc: other"))
  end

  def test_expiry_and_future_plan_guards
    [{ 'expires_at' => @now.iso8601 }, { 'issued_at' => (@now + 1).iso8601 },
      { 'issued_at' => (@now - 601).iso8601 }, { 'expires_at' => (@now + 601).iso8601 },
      { 'issued_at' => 'invalid' }].each { |change| rejects_without_attempt(plan: @plan.merge(change)) }
  end

  def test_actual_mail_constructor_rejects_weaker_tls_before_any_attempt
    [{ tls: false }, { openssl_verify_mode: 'none' }, { port: '587' }, { enable_starttls_auto: true }].each do |change|
      mailer = Mailer.new(:smtp, @settings.merge(change), { smtp: Mail::SMTP })
      rejects_without_attempt(mailer: mailer)
    end
  end

  def test_production_requires_its_own_explicit_plan_sender_and_current_context
    rejects_without_attempt(env: @env.merge('TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'production'))
    settings = ToybacoSmtpTlsProbe.expected_settings('production').merge(user_name: 'native-user', password: 'native-only-value')
    mailer = Mailer.new(:smtp, settings, { smtp: Mail::SMTP })
    plan = @plan.merge('environment' => 'production', 'sender' => 'no-reply@toybaco.jp')
    ok, output = run_proof(plan: plan, mailer: mailer,
      env: @env.merge('TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'production', 'MAILER_SENDER_EMAIL' => 'Toybaco <no-reply@toybaco.jp>'))
    assert ok
    assert_includes output, 'ACCEPTED attempted=1'
    assert_equal 1, @calls.length
  end

  def test_an_accepted_plan_is_not_sent_twice
    assert run_proof.first
    refute run_proof.first
    assert_equal 1, @calls.length
    assert_equal 1, Dir.children(@directory).length
  end

  def test_ambiguous_transport_error_retains_attempt_and_never_prints_remote_text_or_retries
    @failure = IOError.new('native-only-value owned-release@example.invalid remote free text')
    ok, output = run_proof
    refute ok
    assert_includes output, 'NO_GO attempted=1 reason=delivery_uncertain'
    refute_includes output, 'native-only-value'
    refute_includes output, 'owned-release@example.invalid'
    refute run_proof.first
    assert_equal 1, @calls.length
    assert_equal 1, Dir.children(@directory).length
  end

  def test_non250_or_nonresponse_is_not_acceptance
    [Net::SMTP::Response.parse('200 not-data-acceptance'), Object.new].each_with_index do |response, index|
      @response = response
      ok, output = run_proof(plan: @plan.merge('run_marker' => "smtp-proof-#{index.to_s.rjust(32, '0')}"))
      refute ok
      assert_includes output, 'NO_GO attempted=1 reason=delivery_uncertain mailbox=NOT_OBSERVED'
    end
    assert_equal 2, @calls.length
  end
end
