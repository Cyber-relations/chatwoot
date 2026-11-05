# frozen_string_literal: true

require 'rails_helper'

Rails.application.load_tasks unless Rake::Task.task_defined?('toybaco:unavailable_channel_inventory')

RSpec.describe Toybaco::ChannelInventory do
  let(:line_shape) do
    /\A(?:Channel::[A-Za-z]+ total=\d+|Channel::[A-Za-z]+(?: [a-z_]+=[a-z_]+)+ count=\d+|unavailable_channels_total=\d+)\z/
  end

  before { allow(Toybaco::Ops::Audit).to receive(:around).and_yield }

  it 'prints a zero total for every unavailable channel model when none exist' do
    expect(described_class.lines).to eq(['Channel::Sms total=0', 'Channel::Whatsapp total=0', 'Channel::TwilioSms total=0',
                                         'Channel::TwitterProfile total=0', 'unavailable_channels_total=0'])
  end

  it 'counts existing rows by provider, medium and voice without names, numbers or ids' do
    account = create(:account, name: 'private-store-fixture')
    with_modified_env('TOYBACO_SMS_ENABLED' => 'true', 'TOYBACO_WHATSAPP_ENABLED' => 'true') do
      create(:channel_twilio_sms, :with_voice, account: account)
      create(:channel_whatsapp, provider: 'whatsapp_cloud', account: account, validate_provider_config: false, sync_templates: false)
    end

    lines = described_class.lines
    expect(lines).to include('Channel::TwilioSms total=1', 'Channel::TwilioSms medium=sms voice_enabled=true count=1',
                             'Channel::Whatsapp total=1', 'Channel::Whatsapp provider=whatsapp_cloud count=1',
                             'unavailable_channels_total=2')
    expect(lines).to all(match(line_shape))
    expect(lines.join("\n")).not_to include(account.name, Channel::TwilioSms.sole.phone_number)
  end

  it 'counts an unexpected provider value as other without printing it' do
    leaked = "leak@example.test\nChannel::Sms total=999"
    with_modified_env('TOYBACO_SMS_ENABLED' => 'true') do
      create(:channel_sms, provider: leaked)
      create(:channel_sms)
    end

    lines = described_class.lines
    expect(lines).to include('Channel::Sms total=2', 'Channel::Sms provider=default count=1', 'Channel::Sms provider=other count=1')
    expect(lines.size).to eq(7)
    expect(lines).to all(match(line_shape))
    expect(lines.join("\n")).not_to include('leak@example.test', 'total=999')
  end

  context 'with the real ops audit wrapper' do
    let!(:baseline) { Toybaco::OperatorAction.maximum(:id).to_i }

    before { allow(Toybaco::Ops::Audit).to receive(:around).and_call_original }

    # The audit wrapper commits on its own connection; the append-only trigger is
    # bypassed only by the test database superuser, as in ops_rake_audit_spec.
    after do
      connection = ActiveRecord::Base.connection_db_config.new_connection
      connection.execute('SET session_replication_role = replica')
      connection.execute("DELETE FROM toybaco_operator_actions WHERE id > #{Integer(baseline)}")
    ensure
      connection&.disconnect!
    end

    it 'reads business rows only, while the ops wrapper writes its started and ok audit rows' do
      counts = described_class.models.map(&:count)

      expect { Rake::Task['toybaco:unavailable_channel_inventory'].execute }.to output(/^unavailable_channels_total=0$/).to_stdout

      expect(described_class.models.map(&:count)).to eq(counts)
      expect(Toybaco::OperatorAction.where('id > ?', baseline).order(:id).pluck(:action, :result)).to eq(
        [%w[rake.toybaco:unavailable_channel_inventory started], %w[rake.toybaco:unavailable_channel_inventory ok]]
      )
    end
  end

  it 'prints the same lines from the ops-rake task' do
    task = Rake::Task['toybaco:unavailable_channel_inventory']
    task.reenable

    expect { task.invoke }.to output("#{described_class.lines.join("\n")}\n").to_stdout
  end
end
