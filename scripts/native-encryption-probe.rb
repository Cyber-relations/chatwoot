# frozen_string_literal: true

# Execute on the exact previous Rails image with PGOPTIONS enforcing a read-only
# connection before Rails boots. No secrets or record contents are printed.
phase = 'default_read_only'
model_name = 'none'
field_name = 'none'
begin
  raise 'read-only connection required' unless ActiveRecord::Base.connection.select_value('SHOW default_transaction_read_only') == 'on'
  phase = 'transaction_read_only'
  raise 'read-only transaction required' unless ActiveRecord::Base.connection.select_value('SHOW transaction_read_only') == 'on'
  phase = 'encryption_configuration'
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
    model_name = class_name
    field_name = 'none'
    phase = 'model_lookup'
    model = class_name.constantize
    phase = 'encrypted_fields'
    raise 'native field missing' unless (attributes - model.encrypted_attributes.to_a.map(&:to_s)).empty?

    attributes.each do |attribute|
      field_name = attribute
      phase = 'round_trip'
      value = attribute == 'otp_backup_codes' ? ['native-encryption-probe'] : 'native-encryption-probe'
      type = model.type_for_attribute(attribute)
      serialized = type.serialize(value)
      raise 'encryption round trip failed' unless serialized.is_a?(String) && !serialized.include?('native-encryption-probe') &&
                                                 type.deserialize(serialized) == value
    end
    phase = 'existing_records'
    field_name = 'none'
    model.unscoped.select(model.primary_key, *attributes).find_each(batch_size: 100) do |record|
      attributes.each do |attribute|
        field_name = attribute
        # Read the encrypted Active Record type directly. Public getters such as
        # Instagram#access_token may refresh credentials and need unrelated fields.
        record.read_attribute(attribute)
      end
    end
  end
  puts 'TOYBACO_NATIVE_ENCRYPTION_PROBE=PASS'
rescue StandardError => error
  # Phase and identifiers come only from the static registry above. Never print
  # exception messages, record IDs, attribute values, ciphertext or key material.
  kind = error.class.name.to_s.match?(/\A[A-Za-z][A-Za-z0-9_:]*\z/) ? error.class.name : 'Error'
  warn "TOYBACO_NATIVE_ENCRYPTION_PROBE=DENY; phase=#{phase}; model=#{model_name}; field=#{field_name}; error_type=#{kind}"
  exit 1
end
