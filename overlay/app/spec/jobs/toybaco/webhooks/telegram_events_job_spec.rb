# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::TelegramEventsJob do
  [nil, '', " \t\n"].each do |token|
    it "rejects a blank credential #{token.inspect} before channel lookup or processing" do
      expect(Channel::Telegram).not_to receive(:find_by)
      expect(Telegram::IncomingMessageService).not_to receive(:new)
      expect(Telegram::UpdateMessageService).not_to receive(:new)

      described_class.new.perform(bot_token: token, telegram: { message: { text: 'fixture' } })
    end
  end

  it 'still processes a callback for an active channel with a real credential' do
    inbox = instance_double(Inbox)
    account = instance_double(Account, active?: true)
    channel = instance_double(Channel::Telegram, account: account, inbox: inbox)
    event = { 'message' => { 'text' => 'fixture' } }.with_indifferent_access
    service = instance_double(Telegram::IncomingMessageService, perform: nil)
    allow(Channel::Telegram).to receive(:find_by).with(bot_token: 'synthetic-token').and_return(channel)
    allow(Telegram::IncomingMessageService).to receive(:new).with(inbox: inbox, params: event).and_return(service)

    described_class.new.perform({ 'bot_token' => 'synthetic-token', 'telegram' => event }.with_indifferent_access)

    expect(service).to have_received(:perform).once
  end
end
