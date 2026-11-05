# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::LineEventsJob do
  let(:body) { { events: [] }.to_json }
  let(:inbox) { instance_double(Inbox, id: 1) }
  let(:channel) do
    instance_double(Channel::Line, line_channel_secret: secret, line_channel_id: 'fixture', account_id: 1, inbox: inbox)
  end

  before do
    allow(Channel::Line).to receive(:find_by).with(line_channel_id: 'fixture').and_return(channel)
  end

  [nil, '', " \t\n"].each do |blank_secret|
    context "with a blank channel secret #{blank_secret.inspect}" do
      let(:secret) { blank_secret }

      it 'rejects a signature made with that blank key before HMAC or message processing' do
        signature = Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', secret.to_s, body))
        expect(OpenSSL::HMAC).not_to receive(:digest)
        expect(Line::IncomingMessageService).not_to receive(:new)

        described_class.new.perform(params: { :line_channel_id => 'fixture', 'line' => { 'events' => [] } },
                                    signature: signature, post_body: body)
      end
    end
  end
end
