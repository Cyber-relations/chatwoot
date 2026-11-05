# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::WhatsappEventsJob do
  let(:job) { described_class.new }
  let(:channel) { instance_double(Channel::Whatsapp, reauthorization_required?: false, account: instance_double(Account, active?: true)) }
  let(:body) { { 'content' => 'signed message', 'phone_number' => 'body-number' }.with_indifferent_access }

  # The route contract is for an offered WhatsApp; with the switch off the job is a no-op
  # (Toybaco::ChannelAvailability::ProviderJobBoundaries).
  around { |example| with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') { example.run } }

  before do
    allow(Channel::Whatsapp).to receive(:find_by).with(phone_number: 'route-number').and_return(channel)
  end

  it 'uses the serialized route for lookup while processing the body unchanged' do
    args = ActiveJob::Arguments.deserialize(ActiveJob::Arguments.serialize([body, { route: { phone_number: 'route-number' } }]))
    expect(job).to receive(:process_events).with(channel, body)

    job.perform(args.first, **args.last)
  end

  it 'does not turn a body phone_number into a route when the route is empty' do
    expect(Channel::Whatsapp).not_to receive(:find_by)
    expect(job).not_to receive(:process_events)

    job.perform(body, route: {})
  end

  it 'keeps the pre-existing queued job argument contract' do
    expect(job).to receive(:process_events).with(channel, body.merge(phone_number: 'route-number'))

    job.perform(body.merge(phone_number: 'route-number'))
  end
end
