# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ContactInbox, :provider_stop, type: :model do
  source_ids = {
    cloud: '15555550101', twilio_sms: '+15555550101', twilio_whatsapp: 'whatsapp:+15555550101',
    bandwidth: '+15555550101', twitter: '15555550101'
  }.freeze

  shared_examples 'a valid provider message fixture' do |kind, source_id|
    it "persists the #{kind} recipient in its provider format" do
      message = outgoing_provider_message(available_provider(kind))
      contact_inbox = message.conversation.contact_inbox

      expect(contact_inbox).to be_persisted
      expect(contact_inbox).to be_valid
      expect(contact_inbox.source_id).to eq(source_id)
      expect_no_provider_requests
    end
  end

  source_ids.each { |kind, source_id| it_behaves_like 'a valid provider message fixture', kind, source_id }
end
