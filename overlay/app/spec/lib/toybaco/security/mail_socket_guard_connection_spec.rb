# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::Security::MailSocketGuard do
  let(:host) { 'mail.example.test' }
  let(:public_ip) { '93.184.216.34' }
  let(:helper) { Object.new.extend(Api::V1::InboxesHelper) }
  let(:channel) do
    build_stubbed(:channel_email, imap_address: host, imap_port: 993, imap_enabled: true,
                                  smtp_address: host, smtp_port: 587, smtp_enabled: true)
  end

  before do
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).and_raise(RSpec::Expectations::ExpectationNotMetError, 'unexpected DNS lookup')
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return([public_ip])
    # Exercise the real native clients down to their socket boundary, with no network.
    allow(Socket).to receive(:tcp).and_raise(RSpec::Expectations::ExpectationNotMetError, 'unexpected TCP connection')
    allow(TCPSocket).to receive(:new).and_raise(RSpec::Expectations::ExpectationNotMetError, 'unexpected TCP connection')
    allow(TCPSocket).to receive(:open).and_raise(RSpec::Expectations::ExpectationNotMetError, 'unexpected TCP connection')
  end

  def smtp_data
    { smtp_domain: 'example.test', smtp_login: 'fixture', smtp_password: 'synthetic-password', smtp_authentication: 'login' }
  end

  def channel_smtp
    mailer = ConversationReplyMailer.new
    mailer.instance_variable_set(:@inbox, instance_double(Inbox, inbox_type: 'Email'))
    mailer.instance_variable_set(:@channel, channel)
    mailer.instance_variable_set(:@options, {})
    mailer.send(:set_delivery_method)
    settings = mailer.instance_variable_get(:@options).fetch(:delivery_method_options)
    Mail::SMTP.new(settings).send(:build_smtp_session)
  end

  %w[127.0.0.1 169.254.169.254 ::1 ::ffff:7f00:1].each do |address|
    it "blocks literal IMAP destination #{address} before any socket" do
      expect { Net::IMAP.new(address, port: 993, ssl: true) }.to raise_error(SocketError, /Mail destination/)
      expect(Socket).not_to have_received(:tcp)
    end
  end

  it 'guards the save-time IMAP check' do
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return(['10.0.0.1'])

    expect do
      helper.send(:build_imap_connection, { imap_address: host, imap_port: 993, imap_enable_ssl: true })
    end.to raise_error(SocketError, /Mail destination/)
    expect(Socket).not_to have_received(:tcp)
  end

  it 'refuses an unresolvable IMAP name before opening a socket' do
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return([])

    expect { Net::IMAP.new(host, port: 993, ssl: true) }.to raise_error(SocketError, /Mail destination/)
    expect(Socket).not_to have_received(:tcp)
    expect(TCPSocket).not_to have_received(:open)
  end

  it 'refuses an unresolvable SMTP name before opening a socket' do
    smtp = channel_smtp
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return([])

    expect { smtp.start('example.test') }.to raise_error(SocketError, /Mail destination/)
    expect(Socket).not_to have_received(:tcp)
    expect(TCPSocket).not_to have_received(:open)
  end

  it 'rejects the entire DNS answer before connecting when a fallback address is private' do
    smtp = channel_smtp
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return([public_ip, '127.0.0.1'])

    expect { smtp.start('example.test') }.to raise_error(SocketError, /Mail destination/)
    expect(Socket).not_to have_received(:tcp)
    expect(TCPSocket).not_to have_received(:open)
  end

  it 'rejects a non-mail IMAP port before DNS or socket creation' do
    expect { Net::IMAP.new(host, port: 6379, ssl: false) }.to raise_error(SocketError, /Mail destination/)
    expect(Toybaco::Security::MailResolver).not_to have_received(:getaddresses)
    expect(Socket).not_to have_received(:tcp)
  end

  it 'guards the save-time SMTP check' do
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return(['100.64.0.1'])
    smtp = Net::SMTP.new(host, 587)

    expect { helper.send(:check_smtp_connection, smtp_data, smtp) }.to raise_error(StandardError, I18n.t('errors.inboxes.smtp.connection_error'))
    expect(TCPSocket).not_to have_received(:open)
  end

  it 'rechecks persisted settings in the periodic IMAP fetcher before authentication' do
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return(['fd00:ec2::254'])
    service = Imap::FetchEmailService.new(channel: channel)
    expect(Imap::Authentication).not_to receive(:authenticate!)

    expect { service.send(:build_imap_client) }.to raise_error(SocketError, /Mail destination/)
    expect(Socket).not_to have_received(:tcp)
  end

  it 'rejects an unsafe trial IMAP destination as a failed sign-in without a socket' do
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return(['169.254.169.254'])
    verification = Toybaco::Growth::ImapVerification

    expect(verification.signed_in?(channel, verification.snapshot(channel))).to be(false)
    expect(Socket).not_to have_received(:tcp)
  end

  it 'guards channel SMTP delivery after the settings were saved' do
    smtp = channel_smtp
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return(['192.168.0.1'])

    expect { smtp.start('example.test') }.to raise_error(SocketError, /Mail destination/)
    expect(TCPSocket).not_to have_received(:open)
  end

  it 'rejects a non-mail SMTP port in an existing channel at delivery time' do
    channel.smtp_port = 22
    smtp = channel_smtp

    expect { smtp.start('example.test') }.to raise_error(SocketError, /Mail destination/)
    expect(Toybaco::Security::MailResolver).not_to have_received(:getaddresses)
    expect(TCPSocket).not_to have_received(:open)
  end

  it 'also guards legacy OAuth SMTP delivery' do
    mailer = ConversationReplyMailer.new
    mailer.instance_variable_set(:@channel, channel)
    allow(channel).to receive(:provider_config).and_return('access_token' => 'synthetic-oauth-token')
    settings = mailer.send(:base_smtp_settings, 'smtp.gmail.com')
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with('smtp.gmail.com', timeout: anything).and_return(['127.0.0.1'])
    smtp = Mail::SMTP.new(settings).send(:build_smtp_session)

    expect { smtp.start('example.test') }.to raise_error(SocketError, /Mail destination/)
    expect(TCPSocket).not_to have_received(:open)
  end

  it 'pins the IMAP socket to the checked IP and retains the TLS hostname' do
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return([public_ip], ['127.0.0.1'])
    allow(Socket).to receive(:tcp).with(public_ip, 993, any_args).and_raise(IOError, 'checked socket reached')
    client = Net::IMAP.allocate

    expect { client.send(:initialize, host, port: 993, ssl: true) }.to raise_error(IOError, 'checked socket reached')
    expect(client.instance_variable_get(:@host)).to eq(host)
    expect(Toybaco::Security::MailResolver).to have_received(:getaddresses).with(host, timeout: anything).once
    expect(Socket).to have_received(:tcp).with(public_ip, 993, any_args).once
  end

  it 'pins the SMTP socket and resolves afresh on each connection attempt' do
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return([public_ip], ['127.0.0.1'])
    smtp = channel_smtp
    allow(Socket).to receive(:tcp).with(public_ip, 587, nil, nil, connect_timeout: smtp.open_timeout)
                                  .and_raise(IOError, 'checked socket reached')

    expect { smtp.start('example.test') }.to raise_error(IOError, 'checked socket reached')
    expect(smtp.address).to eq(host)
    expect { smtp.start('example.test') }.to raise_error(SocketError, /Mail destination/)
    expect(Socket).to have_received(:tcp).with(public_ip, 587, nil, nil, connect_timeout: smtp.open_timeout).once
    expect(TCPSocket).not_to have_received(:open)
    expect(Toybaco::Security::MailResolver).to have_received(:getaddresses).with(host, timeout: anything).twice
  end

  %i[imap smtp].each do |protocol|
    [Errno::ENETUNREACH, Errno::ECONNREFUSED, Net::OpenTimeout].each do |failure|
      it "falls back within the checked #{protocol} address set after #{failure}" do
        ipv6 = '2606:4700:4700::1111'
        port = protocol == :imap ? 993 : 587
        allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return([ipv6, public_ip], ['127.0.0.1'])
        allow(Socket).to receive(:tcp).with(ipv6, port, any_args).and_raise(failure)
        allow(Socket).to receive(:tcp).with(public_ip, port, any_args).and_raise(IOError, 'checked fallback reached')
        client = protocol == :imap ? Net::IMAP.allocate : channel_smtp

        expect do
          if protocol == :imap
            client.send(:initialize, host, port: port, ssl: true, open_timeout: 30)
          else
            client.start('example.test')
          end
        end.to raise_error(IOError, 'checked fallback reached')
        expect(Toybaco::Security::MailResolver).to have_received(:getaddresses).with(host, timeout: anything).once
        expect(Socket).to have_received(:tcp).with(ipv6, port, any_args).once
        expect(Socket).to have_received(:tcp).with(public_ip, port, any_args).once
        expect(protocol == :imap ? client.instance_variable_get(:@host) : client.address).to eq(host)
      end
    end
  end

  it 'bounds the entire fallback sequence even if the native timeout is nil' do
    smtp = channel_smtp
    smtp.open_timeout = nil
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return([public_ip, '1.1.1.1'])
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(100, 100, 100, 131)
    allow(Socket).to receive(:tcp).with(public_ip, 587, nil, nil, connect_timeout: nil).and_raise(Errno::ECONNREFUSED)
    expect(Timeout).to receive(:timeout).with(15.0, Net::OpenTimeout).and_call_original

    expect { smtp.send(:tcp_socket, host, 587) }.to raise_error(Net::OpenTimeout, 'Mail connection timeout')
    expect(Socket).not_to have_received(:tcp).with('1.1.1.1', any_args)
    expect(smtp.open_timeout).to be_nil
  end

  it 'does not change the installation SMTP transport' do
    smtp = Mail::SMTP.new(address: host, port: 587).send(:build_smtp_session)

    expect(smtp).not_to be_a(described_class)
  end

  it 'includes stalled DNS in the connection budget without opening a socket' do
    dns = instance_double(Resolv::DNS, close: nil)
    resolver = instance_double(Resolv)
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).and_call_original
    allow(Resolv::DNS).to receive(:new).and_return(dns)
    allow(dns).to receive(:timeouts=)
    allow(Resolv).to receive(:new).and_return(resolver)
    allow(resolver).to receive(:getaddresses) { Queue.new.pop }
    smtp = channel_smtp
    smtp.open_timeout = 0.05
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    Timeout.timeout(2) do
      expect { smtp.send(:tcp_socket, host, 587) }.to raise_error(Net::OpenTimeout, 'Mail connection timeout')
    end

    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
    expect(Socket).not_to have_received(:tcp)
    expect(TCPSocket).not_to have_received(:open)
    expect(TCPSocket).not_to have_received(:new)
    expect(dns).to have_received(:close)
  end
end
