# frozen_string_literal: true

# Run with `rails runner` only in an isolated disposable database. No emails,
# credentials or token values are emitted, and every user is synthetic.
require 'json'

abort 'disposable opt-in required' unless ENV['TOYBACO_CASA_DISPOSABLE'] == 'true'
abort 'unexpected database' unless ENV['POSTGRES_DATABASE'] == 'toybaco_casa_disposable'
abort 'unexpected host' unless ENV['FRONTEND_URL'] == 'https://casa-fixture.invalid'
abort 'mail transport must be disabled' if Rails.application.config.action_mailer.perform_deliveries

results = []
begin
  check = lambda do |name, value|
    results << { name: name, pass: value == true }
  end
  new_user = lambda do |label|
    password = "Local!#{SecureRandom.hex(24)}9a"
    User.create!(name: "Synthetic #{label}", email: "expiry-#{label}-#{SecureRandom.hex(6)}@example.invalid",
                 password: password, password_confirmation: password)
  end

  check.call('confirmation lifetime is seventy-two hours', User.confirm_within == 3.days)
  check.call('password-reset lifetime remains six hours', User.reset_password_within == 6.hours)

  fresh = new_user.call('fresh')
  fresh_token = fresh.confirmation_token
  fresh.update_columns(confirmation_sent_at: 71.hours.ago)
  confirmed = User.confirm_by_token(fresh_token)
  check.call('fresh activation succeeds', confirmed.errors.empty? && fresh.reload.confirmed?)
  replay = User.confirm_by_token(fresh_token)
  check.call('successful activation cannot be replayed', replay.errors.any? && fresh.reload.confirmed?)

  expired = new_user.call('expired')
  old_token = expired.confirmation_token
  expired.update_columns(confirmation_sent_at: 73.hours.ago)
  rejected = User.confirm_by_token(old_token)
  check.call('expired activation is rejected', rejected.errors.of_kind?(:email, :confirmation_period_expired) && !expired.reload.confirmed?)
  check.call('expired activation does not enable login', !expired.active_for_authentication?)
  # The HTTP resend endpoint looks up a new model instance; the creation instance
  # still memoizes its raw token and does not represent a later resend request.
  User.send_confirmation_instructions(email: expired.email)
  new_token = expired.reload.confirmation_token
  check.call('resend rotates expired token and resets its timestamp', new_token != old_token && expired.confirmation_sent_at > 1.minute.ago)
  old_retry = User.confirm_by_token(old_token)
  check.call('old token remains rejected after resend', old_retry.errors.any? && !expired.reload.confirmed?)
  new_confirmation = User.confirm_by_token(new_token)
  check.call('resent activation succeeds', new_confirmation.errors.empty? && expired.reload.confirmed?)

  email_change = new_user.call('email-change')
  User.confirm_by_token(email_change.confirmation_token)
  original_email = email_change.reload.email
  email_change.update!(email: "expiry-new-#{SecureRandom.hex(6)}@example.invalid")
  change_token = email_change.reload.confirmation_token
  check.call('email change waits for confirmation', email_change.email == original_email && email_change.unconfirmed_email.present?)
  email_change.update_columns(confirmation_sent_at: 73.hours.ago)
  change_rejected = User.confirm_by_token(change_token)
  check.call('expired email-change token cannot change the verified address', change_rejected.errors.any? && email_change.reload.email == original_email)
  check.call('confirmed user stays enabled after expired email-change link', email_change.confirmed? && email_change.active_for_authentication?)

  puts JSON.generate(checked_at: Time.now.utc.iso8601, scope: 'Actual Devise/User activation, replay, expiry, resend and email-change flows on isolated synthetic data; not live SMTP/browser or all CASA controls', results: results, all_expected: results.all? { |item| item[:pass] })
  abort 'confirmation expiry regression failed' unless results.all? { |item| item[:pass] }
rescue StandardError => error
  puts JSON.generate(scope: 'Isolated confirmation expiry regression', results: results, all_expected: false,
                     execution_error: { class: error.class.name, locations: error.backtrace.first(6).map { |frame| frame.split(':in').first } })
  exit 1
end
