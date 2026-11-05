# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Seeders::InboxSeeder do
  let(:account) { create(:account) }
  let(:seeder) { described_class.new(account: account, company_data: { 'name' => 'Fixture Co', 'domain' => 'fixture.test' }) }
  let(:unavailable_counts) { -> { [Inbox.count, Channel::TwitterProfile.count, Channel::Whatsapp.count, Channel::Sms.count] } }

  before { allow(Rails.logger).to receive(:info) }

  seeders = { seed_twitter_inbox: 'twitter', seed_whatsapp_inbox: 'whatsapp', seed_sms_inbox: 'sms' }.freeze

  [nil, 'false'].each do |disabled|
    context "when the unavailable channel switches are #{disabled.inspect}" do
      around do |example|
        switches = %w[TOYBACO_SMS_ENABLED TOYBACO_WHATSAPP_ENABLED TOYBACO_TWITTER_ENABLED].index_with { disabled }
        with_modified_env(switches) { example.run }
      end

      seeders.each do |method_name, type|
        it "skips #{method_name} before writing a channel or inbox" do
          account

          expect { seeder.public_send(method_name) }.not_to(change(&unavailable_counts))
          expect(Rails.logger).to have_received(:info).with("Toybaco seeder skipped: #{type} channel is not offered").once
        end
      end
    end
  end

  it 'keeps the upstream WhatsApp seeder when WhatsApp is explicitly enabled' do
    account

    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') do
      expect { seeder.seed_whatsapp_inbox }.to change(Channel::Whatsapp, :count).by(1).and change(Inbox, :count).by(1)
    end
  end
end
