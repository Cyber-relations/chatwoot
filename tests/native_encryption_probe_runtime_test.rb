# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'

raise 'ephemeral CI database required' unless Rails.env.test? && ENV['POSTGRES_HOST'] == 'postgres' && ENV['POSTGRES_DATABASE'] == 'chatwoot_test'

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class NativeEncryptionProbeRuntimeTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  FIXTURE_TOKEN = 'native-probe-expired-instagram-fixture'

  def setup
    @connection = ActiveRecord::Base.connection
    @adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    assert Chatwoot.encryption_configured?
    assert_equal 'off', @connection.select_value('SHOW default_transaction_read_only')
    @account = FactoryBot.create(:account)
    # Insert without channel callbacks: this test must never contact Instagram.
    @channel_id = Channel::Instagram.insert_all!([
      { account_id: @account.id, instagram_id: "probe-#{SecureRandom.uuid}",
        access_token: FIXTURE_TOKEN, expires_at: 1.day.ago, created_at: Time.current, updated_at: Time.current }
    ]).rows.first.first
    @ciphertext = @connection.select_value("SELECT access_token FROM channel_instagram WHERE id = #{@channel_id.to_i}")
    refute_includes @ciphertext, FIXTURE_TOKEN
  end

  def teardown
    @connection.execute('SET default_transaction_read_only = off') if @connection
    Channel::Instagram.where(id: @channel_id).delete_all if @channel_id
    @account&.destroy!
    ActiveJob::Base.queue_adapter = @adapter if @adapter
  end

  def probe
    @connection.execute('SET default_transaction_read_only = on')
    Instagram::RefreshOauthTokenService.stub(:new, ->(*) { raise 'credential refresh must never run' }) do
      load File.expand_path('../scripts/native-encryption-probe.rb', __dir__)
    end
  end

  def test_existing_expired_instagram_reads_encrypted_type_without_public_getter
    output, errors = capture_io { probe }
    assert_equal "TOYBACO_NATIVE_ENCRYPTION_PROBE=PASS\n", output
    assert_empty errors
    assert_equal @ciphertext, @connection.select_value("SELECT access_token FROM channel_instagram WHERE id = #{@channel_id.to_i}")
    refute_includes output, FIXTURE_TOKEN
  end

  def test_corrupt_existing_ciphertext_is_denied_without_disclosing_values
    envelope = JSON.parse(@ciphertext)
    envelope.fetch('p')[0] = envelope.fetch('p')[0] == 'A' ? 'B' : 'A'
    corrupted = JSON.generate(envelope)
    @connection.execute("UPDATE channel_instagram SET access_token = #{@connection.quote(corrupted)} WHERE id = #{@channel_id.to_i}")
    output, errors = capture_io do
      assert_equal 1, assert_raises(SystemExit) { probe }.status
    end
    assert_empty output
    assert_equal "TOYBACO_NATIVE_ENCRYPTION_PROBE=DENY; phase=existing_records; model=Channel::Instagram; field=access_token; error_type=ActiveRecord::Encryption::Errors::Decryption\n", errors
    refute_includes errors, FIXTURE_TOKEN
    refute_includes errors, corrupted
    assert_equal corrupted, @connection.select_value("SELECT access_token FROM channel_instagram WHERE id = #{@channel_id.to_i}")
  end

  def test_legacy_plaintext_is_read_without_refresh_or_rewriting
    @connection.execute("UPDATE channel_instagram SET access_token = #{@connection.quote(FIXTURE_TOKEN)} WHERE id = #{@channel_id.to_i}")
    output, errors = capture_io { probe }
    assert_equal "TOYBACO_NATIVE_ENCRYPTION_PROBE=PASS\n", output
    assert_empty errors
    assert_equal FIXTURE_TOKEN, @connection.select_value("SELECT access_token FROM channel_instagram WHERE id = #{@channel_id.to_i}")
  end
end
