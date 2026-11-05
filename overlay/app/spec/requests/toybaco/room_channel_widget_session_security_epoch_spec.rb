# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RoomChannel, type: :channel do
  include_context 'with a widget session established before the security epoch'

  def connect_widget(credential, with_cookie: true)
    env = Rack::MockRequest.env_for('https://chatwoot.test/cable', 'HTTP_ORIGIN' => 'https://chatwoot.test')
    env['HTTP_COOKIE'] = "#{cookie_name}=#{cookie}" if with_cookie
    @connection = ApplicationCable::Connection.new(ActionCable.server, env)
    subscribe(pubsub_token: "tbwhttp1.#{widget.website_token}.#{credential}")
  end

  cookie_modes = [true, false]
  %i[legacy_jwt cross_visitor_merge].product(%i[environment persisted]).each do |origin, source|
    context "when a #{origin} session has been upgraded with a #{source} cutoff" do
      let(:establishment) { origin }
      let(:epoch_source) { source }

      it 'rejects an HTTP cookie subscription established before cutover' do
        old_proof = proof
        stub_epoch(cutoff)
        connect_widget(old_proof)
        expect(subscription).to be_rejected
        expect(subscription.send(:streams)).to be_empty
      end

      it 'rejects a cookieless recovery subscription established before cutover' do
        old_recovery = recovery
        stub_epoch(cutoff)
        connect_widget(old_recovery, with_cookie: false)
        expect(subscription).to be_rejected
        expect(subscription.send(:streams)).to be_empty
      end

      cookie_modes.each do |with_cookie|
        it "keeps a post-cutover #{with_cookie ? 'HTTP' : 'recovery'} session connected" do
          stub_epoch(cutoff)
          row.update!(created_at: cutoff + 1.second)
          connect_widget(with_cookie ? proof : recovery, with_cookie: with_cookie)
          expect(subscription).to be_confirmed
          expect(subscription).to have_stream_from(link.pubsub_token)
          expect(subscription.send(:verify_toybaco_session)).to be(true)
        end

        it "closes an already subscribed #{with_cookie ? 'HTTP' : 'recovery'} connection at its next validity check" do
          connect_widget(with_cookie ? proof : recovery, with_cookie: with_cookie)
          expect(subscription).to be_confirmed
          expect(subscription).to have_stream_from(link.pubsub_token)
          stub_epoch(cutoff)
          expect(connection).to receive(:close).with(reconnect: false)
          expect(subscription.send(:verify_toybaco_session)).to be(false)
          expect(subscription.send(:streams)).to be_empty
        end
      end
    end
  end
end
