# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::TelegramEventsJob do
  let(:output) { StringIO.new }
  let(:token) { 'synthetic-unknown-bot-credential' }
  let(:account) { instance_double(Account, id: 7, active?: false) }
  let(:channel) { instance_double(Channel::Telegram, id: 9, account: account) }

  before do
    # Deliberately bypass the final scrubber to test the source log statements.
    allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(output))
  end

  it 'does not log an unknown Telegram credential, even without the final filter' do
    allow(Channel::Telegram).to receive(:find_by).with(bot_token: token).and_return(nil)

    described_class.new.perform(bot_token: token)

    aggregate_failures do
      expect(output.string).to include('Telegram event discarded: Channel not found')
      expect(output.string).not_to include(token, 'bot_token')
    end
  end

  it 'keeps the channel and account IDs for an inactive Telegram account' do
    allow(Channel::Telegram).to receive(:find_by).and_return(channel)

    described_class.new.perform(bot_token: 'synthetic-unused-token')

    aggregate_failures do
      expect(output.string).to include('Account 7 is not active for channel 9')
      expect(output.string).not_to include('synthetic-unused-token')
    end
  end
end
