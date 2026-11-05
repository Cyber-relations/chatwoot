# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Channel::Email do
  let(:host) { 'mail.example.test' }
  let(:channel) { create(:channel_email) }

  before do
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).and_raise('unexpected DNS lookup')
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return(['93.184.216.34'])
  end

  optional_ports = [nil, '', ' ']
  %w[imap smtp].each do |protocol|
    context "with #{protocol} settings" do
      let(:attributes) { { "#{protocol}_address" => host, "#{protocol}_port" => 993, "#{protocol}_enabled" => true } }

      it 'rejects private DNS results on save without changing persisted settings' do
        allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return(['10.0.0.1'])

        expect(channel.update(attributes)).to be(false)
        expect(channel.errors["#{protocol}_address"]).to be_present
        expect(channel.reload.public_send("#{protocol}_enabled")).to be(false)
      end

      it 'does not validate the host or port when the protocol is disabled' do
        expect(Toybaco::Security::MailResolver).not_to receive(:getaddresses)

        expect(channel.update(attributes.merge("#{protocol}_enabled" => false, "#{protocol}_port" => 6379))).to be(true)
        expect(channel.update("#{protocol}_address" => '::ffff:127.0.0.1')).to be(true)
        expect(channel.reload.public_send("#{protocol}_address")).to eq('::ffff:127.0.0.1')
      end

      it 'does not validate a disabled protocol when the other protocol is enabled' do
        other_protocol = protocol == 'imap' ? 'smtp' : 'imap'
        other_attributes = { "#{other_protocol}_enabled" => true, "#{other_protocol}_address" => host, "#{other_protocol}_port" => 993 }

        expect(channel.update(attributes.merge("#{protocol}_enabled" => false, "#{protocol}_address" => '127.0.0.1',
                                               "#{protocol}_port" => 6379).merge(other_attributes))).to be(true)
      end

      it 'creates a channel with an unresolvable name' do
        unresolved_host = 'imap.e2e-imap.invalid'
        allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(unresolved_host, timeout: anything).and_return([])
        new_channel = build(:channel_email, account: create(:account))
        new_channel.assign_attributes(attributes.merge("#{protocol}_address" => unresolved_host))

        expect(new_channel.save).to be(true)
        expect(new_channel.reload.public_send("#{protocol}_address")).to eq(unresolved_host)
        expect(new_channel.public_send("#{protocol}_enabled")).to be(true)
      end

      it 'allows updating to an unresolvable name' do
        allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return([])

        expect(channel.update(attributes)).to be(true)
        expect(channel.reload.public_send("#{protocol}_address")).to eq(host)
      end

      it 'accepts a stalled DNS name on save within the separate validation budget' do
        dns = instance_double(Resolv::DNS, close: nil)
        resolver = instance_double(Resolv)
        allow(Toybaco::Security::MailResolver).to receive(:getaddresses).and_call_original
        allow(Resolv::DNS).to receive(:new).and_return(dns)
        allow(dns).to receive(:timeouts=)
        allow(Resolv).to receive(:new).and_return(resolver)
        allow(resolver).to receive(:getaddresses) { Queue.new.pop }
        stub_const('Toybaco::Security::MailDestination::SAVE_DNS_TIMEOUT', 0.05)
        channel
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        Timeout.timeout(2) { expect(channel.update(attributes)).to be(true) }

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
        expect(channel.reload.public_send("#{protocol}_address")).to eq(host)
        expect(dns).to have_received(:timeouts=).with([0.05])
        expect(dns).to have_received(:close)
      end

      [Resolv::ResolvError, Resolv::ResolvTimeout, SocketError].each do |error|
        it "allows saving when resolution raises #{error}" do
          allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_raise(error)

          expect(channel.update(attributes)).to be(true)
          expect(channel.reload.public_send("#{protocol}_address")).to eq(host)
        end
      end

      optional_ports.each do |port|
        it "preserves the upstream optional port when it is #{port.inspect}" do
          expect(channel.update(attributes.merge("#{protocol}_port" => port))).to be(true)
          expect(channel.reload.public_send("#{protocol}_port")).to be_nil
        end
      end

      it 'still rejects a private destination when the port is omitted' do
        allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return(['10.0.0.1'])

        expect(channel.update(attributes.merge("#{protocol}_port" => nil))).to be(false)
      end

      it 'keeps an incomplete enabled channel saveable until a host is configured' do
        expect(Toybaco::Security::MailResolver).not_to receive(:getaddresses)

        expect(channel.update("#{protocol}_enabled" => true, "#{protocol}_login" => ' ')).to be(true)
        expect(channel.reload.public_send("#{protocol}_address")).to be_blank
        expect(channel.public_send("#{protocol}_port")).to eq(0)
      end

      it 'rejects a non-mail port even before a host is configured' do
        expect(Toybaco::Security::MailResolver).not_to receive(:getaddresses)

        expect(channel.update("#{protocol}_enabled" => true, "#{protocol}_port" => 6379)).to be(false)
      end

      it 'rejects a forbidden IP literal without resolving it' do
        expect(Toybaco::Security::MailResolver).not_to receive(:getaddresses)

        expect(channel.update(attributes.merge("#{protocol}_address" => '::ffff:127.0.0.1'))).to be(false)
        expect(channel.errors["#{protocol}_address"]).to be_present
      end

      it 'rejects a non-mail port on save' do
        expect(channel.update(attributes.merge("#{protocol}_port" => 6379))).to be(false)
      end

      it 'rejects a DNS answer containing both public and private addresses' do
        allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return(['93.184.216.34', 'fc00::1'])

        expect(channel.update(attributes)).to be(false)
      end

      it 'saves a public destination on an allowed port' do
        expect(channel.update(attributes)).to be(true)
        expect(channel.reload.public_send("#{protocol}_address")).to eq(host)
      end

      it 'rechecks DNS when enabling previously saved settings' do
        channel.update!(attributes.merge("#{protocol}_enabled" => false))
        allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return(['169.254.169.254'])

        expect(channel.update("#{protocol}_enabled" => true)).to be(false)
      end

      it 'rechecks DNS when saving a changed password for an existing destination' do
        channel.update!(attributes)
        allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return(['127.0.0.1'])

        expect(channel.update("#{protocol}_password" => 'changed-synthetic-password')).to be(false)
      end
    end
  end
end
