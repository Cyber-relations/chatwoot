# frozen_string_literal: true

require 'rails/test_help'
require 'stringio'

class ToybacoFetchErrorLoggingRuntimeTest < ActiveSupport::TestCase
  self.use_transactional_tests = true

  def test_avatar_errors_never_log_secret_url_components
    account = Account.create!(name: 'Synthetic error log boundary')
    %w[query userinfo].each do |kind|
      marker = SecureRandom.hex(24)
      contact = Contact.create!(account: account, name: 'Synthetic', email: "#{SecureRandom.hex(6)}@example.invalid")
      text = capture_log { Avatar::AvatarFromUrlJob.new.perform(contact, secret_url(kind, marker)) }
      assert_includes text, 'AvatarFromUrlJob'
      refute_includes text, marker
      refute contact.avatar.attached?
    end
  end

  def test_webhook_errors_never_log_secret_url_components
    %w[query userinfo].each do |kind|
      marker = SecureRandom.hex(24)
      text = capture_log { Webhooks::Trigger.execute(secret_url(kind, marker), { event: 'synthetic' }, :custom_webhook) }
      assert_includes text, 'Webhook delivery failed'
      refute_includes text, marker
    end
  end

  private

  def secret_url(kind, marker)
    kind == 'query' ? "http://127.0.0.1/avatar.png?access_token=#{marker}" : "http://synthetic:#{marker}@127.0.0.1/avatar.png"
  end

  def capture_log
    previous = Rails.logger
    capture = StringIO.new
    Rails.logger = ActiveSupport::Logger.new(capture)
    yield
    capture.string
  ensure
    Rails.logger = previous
  end
end
