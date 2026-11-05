# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::InstagramEventsJob do
  let(:output) { StringIO.new }
  let(:messaging) do
    { sender: { id: '11' }, recipient: { id: '22' }, message: { text: 'private synthetic message', mid: 'fixture-mid' } }
  end
  # The dispatcher selects the service with is_a?(Channel::Instagram).
  let(:channel) { build_stubbed(:channel_instagram) }
  let(:service) { instance_double(Instagram::MessageText, perform: nil) }

  before do
    # Deliberately bypass the final scrubber to test the source log statements.
    allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(output))
    allow(Channel::Instagram).to receive(:find_by).with(instagram_id: '22').and_return(channel)
    allow(Instagram::MessageText).to receive(:new).and_return(service)
  end

  %w[messaging standby].each do |key|
    it "logs counts while delivering the original Instagram #{key} content" do
      described_class.new.process_entries([{ key => [messaging] }])

      aggregate_failures do
        expect(output.string).to include('messages_count=1')
        expect(output.string).not_to include('private synthetic message', 'fixture-mid')
        expect(Instagram::MessageText).to have_received(:new).with(messaging.with_indifferent_access, channel)
        expect(service).to have_received(:perform)
      end
    end
  end
end
