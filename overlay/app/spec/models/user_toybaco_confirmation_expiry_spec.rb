# frozen_string_literal: true

require 'rails_helper'

RSpec.describe User do
  def unconfirmed_user
    password = "Synthetic!#{SecureRandom.hex(24)}9a"
    described_class.create!(
      name: 'Synthetic expiry user', email: "expiry-#{SecureRandom.hex(8)}@example.invalid",
      password: password, password_confirmation: password
    )
  end

  it 'limits activation to 24 hours without changing password reset expiry' do
    expect(described_class.confirm_within).to eq(24.hours)
    expect(described_class.reset_password_within).to eq(6.hours)
  end

  it 'accepts a 23-hour activation once' do
    user = unconfirmed_user
    token = user.confirmation_token
    user.update!(confirmation_sent_at: 23.hours.ago)
    expect(described_class.confirm_by_token(token).errors.empty?).to be(true)
    expect(user.reload.confirmed?).to be(true)
    expect(described_class.confirm_by_token(token).errors.any?).to be(true)
  end

  it 'rejects a 25-hour token and rotates it on resend' do
    user = unconfirmed_user
    old_token = user.confirmation_token
    user.update!(confirmation_sent_at: 25.hours.ago)
    rejected = described_class.confirm_by_token(old_token)
    expect(rejected.errors.of_kind?(:email, :confirmation_period_expired)).to be(true)
    expect(user.reload.active_for_authentication?).to be(false)
    described_class.send_confirmation_instructions(email: user.email)
    new_token = user.reload.confirmation_token
    expect(new_token == old_token).to be(false)
    expect(described_class.confirm_by_token(old_token).errors.any?).to be(true)
    expect(described_class.confirm_by_token(new_token).errors.empty?).to be(true)
  end

  it 'keeps a confirmed user enabled when email-change confirmation expires' do
    user = unconfirmed_user
    described_class.confirm_by_token(user.confirmation_token)
    original_email = user.reload.email
    user.update!(email: "expiry-new-#{SecureRandom.hex(8)}@example.invalid")
    token = user.reload.confirmation_token
    user.update!(confirmation_sent_at: 25.hours.ago)
    expect(described_class.confirm_by_token(token).errors.any?).to be(true)
    expect(user.reload.email).to eq(original_email)
    expect(user.active_for_authentication?).to be(true)
  end
end
