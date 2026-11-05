# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::Security::MailDestination do
  let(:host) { 'mail.example.test' }

  before do
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).and_raise('unexpected DNS lookup')
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return(['93.184.216.34'])
  end

  it 'retains every validated address in order, normalizing and deduplicating them' do
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything)
                                                                    .and_return(['2606:4700:4700::1111', '93.184.216.34', '::ffff:93.184.216.34'])

    expect(described_class.resolve_all!(host, 993)).to eq(['2606:4700:4700::1111', '93.184.216.34'])
    expect(Toybaco::Security::MailResolver).to have_received(:getaddresses).with(host, timeout: anything).once
  end

  %w[0.0.0.0 10.1.2.3 127.0.0.1 169.254.169.254 172.16.1.2 192.168.1.2 100.100.100.200
     224.0.0.1 255.255.255.255 168.63.129.16 :: ::1 fe80::1 febf::1 fc00::1 fd00:ec2::254 ff02::1
     ::ffff:127.0.0.1 ::ffff:7f00:1 ::ffff:169.254.169.254 ::ffff:a00:1].each do |address|
    it "rejects #{address} in a DNS answer" do
      allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return([address])

      expect { described_class.resolve!(host, 993) }.to raise_error(SocketError, /Mail destination/)
    end
  end

  [[], ['93.184.216.34', '10.0.0.1'], ['invalid-address']].each do |addresses|
    it "fails closed for DNS results #{addresses.inspect}" do
      allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return(addresses)

      expect { described_class.resolve!(host, 993) }.to raise_error(SocketError, /Mail destination/)
    end
  end

  it 'fails closed on resolver errors without exposing the host in the error' do
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_raise(Resolv::ResolvError, host)

    expect { described_class.resolve!(host, 993) }.to raise_error(SocketError, described_class::ERROR)
  end

  [25, 465, 587, 2525, 143, 993].each do |port|
    it "allows standard mail port #{port}" do
      expect(described_class.resolve!(host, port.to_s)).to eq('93.184.216.34')
    end
  end

  [0, 22, 80, 443, 6379, -1, '993junk', nil].each do |port|
    it "rejects port #{port.inspect} before resolution" do
      expect(Toybaco::Security::MailResolver).not_to receive(:getaddresses)

      expect { described_class.resolve!(host, port) }.to raise_error(SocketError, /Mail destination/)
    end
  end

  %w[imap.gmail.com smtp.gmail.com outlook.office365.com smtp.office365.com sv12345.xserver.jp].each do |mail_host|
    it "allows a public DNS result for #{mail_host}" do
      allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(mail_host, timeout: anything)
                                                                      .and_return(['93.184.216.34', '2606:4700:4700::1111'])

      expect(described_class.resolve!(mail_host, 993)).to eq('93.184.216.34')
    end
  end

  it 'allows public IPv6 and normalizes public IPv4-mapped IPv6' do
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything)
                                                                    .and_return(['2606:4700:4700::1111'], ['::ffff:93.184.216.34'])

    expect(described_class.resolve!(host, 993)).to eq('2606:4700:4700::1111')
    expect(described_class.resolve!(host, 993)).to eq('93.184.216.34')
  end
end
