# frozen_string_literal: true

# Execute on the exact previous Rails image with PGOPTIONS enforcing a read-only
# connection before Rails boots. No secrets or record contents are printed.
begin
  raise 'read-only connection required' unless ActiveRecord::Base.connection.select_value('SHOW default_transaction_read_only') == 'on'
  raise 'read-only transaction required' unless ActiveRecord::Base.connection.select_value('SHOW transaction_read_only') == 'on'
  raise 'native encryption unavailable' unless Chatwoot.encryption_configured?

  expected = {
    'Channel::Line' => %w[line_channel_secret line_channel_token],
    'Channel::Email' => %w[imap_password smtp_password],
    'Channel::FacebookPage' => %w[page_access_token user_access_token],
    'Channel::Instagram' => %w[access_token],
    'Channel::TwitterProfile' => %w[twitter_access_token twitter_access_token_secret],
    'Channel::Tiktok' => %w[access_token refresh_token],
    'Channel::Telegram' => %w[bot_token],
    'Channel::TwilioSms' => %w[auth_token],
    'Channel::Whatsapp' => %w[business_management_token],
    'Channel::Api' => %w[secret],
    'Webhook' => %w[secret],
    'AgentBot' => %w[secret],
    'DataImport' => %w[access_token],
    'Integrations::Hook' => %w[access_token],
    'User' => %w[otp_secret otp_backup_codes]
  }
  expected.each do |class_name, attributes|
    model = class_name.constantize
    raise 'native field missing' unless (attributes - model.encrypted_attributes.to_a.map(&:to_s)).empty?

    attributes.each do |attribute|
      value = attribute == 'otp_backup_codes' ? ['native-encryption-probe'] : 'native-encryption-probe'
      type = model.type_for_attribute(attribute)
      serialized = type.serialize(value)
      raise 'encryption round trip failed' unless serialized.is_a?(String) && !serialized.include?('native-encryption-probe') &&
                                                 type.deserialize(serialized) == value
    end
    model.unscoped.select(model.primary_key, *attributes).find_each(batch_size: 100) do |record|
      attributes.each { |attribute| record.public_send(attribute) }
    end
  end
  puts 'TOYBACO_NATIVE_ENCRYPTION_PROBE=PASS'
rescue StandardError
  warn 'TOYBACO_NATIVE_ENCRYPTION_PROBE=DENY; existing connection or MFA data cannot be read with the retained keys'
  exit 1
end
