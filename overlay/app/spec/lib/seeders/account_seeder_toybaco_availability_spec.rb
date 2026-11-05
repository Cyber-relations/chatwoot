# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Seeders::AccountSeeder do
  let(:account) { create(:account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:contact) { create(:contact, account: account) }
  let(:switches) { %w[TOYBACO_SMS_ENABLED TOYBACO_WHATSAPP_ENABLED TOYBACO_TWITTER_ENABLED] }

  [nil, 'false'].each do |disabled|
    it "refuses before deleting account data while every unavailable switch is #{disabled.inspect}" do
      with_modified_env(switches.index_with { disabled }) do
        expect { described_class.new(account: account).perform! }
          .to raise_error(ArgumentError, 'Account seeding needs unavailable channels: sms, whatsapp, twitter')
      end

      expect(Inbox.exists?(inbox.id)).to be(true)
      expect(Contact.exists?(contact.id)).to be(true)
    end
  end

  it 'refuses while only one unavailable switch is still off' do
    with_modified_env('TOYBACO_SMS_ENABLED' => 'true', 'TOYBACO_WHATSAPP_ENABLED' => 'true', 'TOYBACO_TWITTER_ENABLED' => nil) do
      expect { described_class.new(account: account).perform! }
        .to raise_error(ArgumentError, 'Account seeding needs unavailable channels: twitter')
    end

    expect(Inbox.exists?(inbox.id)).to be(true)
  end
end
