# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::Security::MailSocketGuard do
  let(:host) { 'mail.example.test' }
  let(:public_ip) { '93.184.216.34' }
  let(:server_names) { [] }
  let(:imap_commands) { [] }
  let(:key) { OpenSSL::PKey::RSA.new(2048) }
  let(:certificate) do
    OpenSSL::X509::Certificate.new.tap do |cert|
      cert.version = 2
      cert.serial = 1
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=#{host}")
      cert.public_key = key.public_key
      cert.not_before = Time.current - 60
      cert.not_after = Time.current + 3600
      cert.sign(key, OpenSSL::Digest.new('SHA256'))
    end
  end
  let(:store) { OpenSSL::X509::Store.new.tap { |value| value.add_cert(certificate) } }
  let(:server_context) do
    OpenSSL::SSL::SSLContext.new.tap do |context|
      context.cert = certificate
      context.key = key
      context.servername_cb = lambda do |(_socket, name)|
        server_names << name
        nil
      end
    end
  end

  before do
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).and_raise(RSpec::Expectations::ExpectationNotMetError, 'unexpected DNS lookup')
    allow(Socket).to receive(:tcp).and_raise(RSpec::Expectations::ExpectationNotMetError, 'unexpected TCP connection')
    allow(TCPSocket).to receive(:open).and_raise(RSpec::Expectations::ExpectationNotMetError, 'unexpected TCP connection')
    allow(TCPSocket).to receive(:new).and_raise(RSpec::Expectations::ExpectationNotMetError, 'unexpected TCP connection')
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return([public_ip])
    allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with('wrong.example.test', timeout: anything).and_return([public_ip])
  end

  # TLS runs over a local UNIX socket pair: no TCP listener, DNS or network.
  # net-smtp 0.3.4 supplies nil local bind arguments and connect_timeout.
  def with_tls_server(protocol, &)
    client_socket, peer = Socket.pair(:UNIX, :STREAM, 0)
    if protocol == :imap
      allow(Socket).to receive(:tcp).with(public_ip, 993, connect_timeout: 30).and_return(client_socket)
    else
      allow(Socket).to receive(:tcp).with(public_ip, 465, nil, nil, connect_timeout: 5).and_return(client_socket)
    end
    server = OpenSSL::SSL::SSLSocket.new(peer, server_context)
    worker = Thread.new { serve_tls_client(server, protocol) }
    Timeout.timeout(5, &)
  ensure
    client_socket&.close
    server&.close
    peer&.close
    worker&.kill
    worker&.join
  end

  def serve_tls_client(socket, protocol)
    socket.accept
    socket.write(protocol == :imap ? "* OK fixture ready\r\n" : "220 fixture ready\r\n")
    while (line = socket.gets)
      socket.write(fixture_reply(protocol, line))
    end
  rescue OpenSSL::SSL::SSLError, IOError, SystemCallError
    # Expected when a client rejects the certificate or the fixture closes.
    nil
  ensure
    socket&.close
  end

  def fixture_reply(protocol, line)
    return imap_fixture_reply(line) if protocol == :imap

    line.start_with?('QUIT') ? "221 closing\r\n" : "250 fixture\r\n"
  end

  def imap_fixture_reply(line)
    tag, command = line.split
    imap_commands << command
    # A tagged OK alone leaves Net::IMAP's capability result nil before LOGIN.
    replies = { 'CAPABILITY' => "* CAPABILITY IMAP4rev1\r\n", 'LOGIN' => '', 'LOGOUT' => "* BYE closing\r\n" }
    return "#{tag} BAD unsupported command\r\n" unless replies.key?(command)

    "#{replies.fetch(command)}#{tag} OK done\r\n"
  end

  def imap_client(name)
    Net::IMAP.new(name, port: 993, open_timeout: 30, ssl: { cert_store: store, verify_mode: OpenSSL::SSL::VERIFY_PEER })
  end

  def smtp_client(name)
    settings = { address: name, port: 465, open_timeout: 5, tls: true, openssl_verify_mode: 'peer', toybaco_public_destination: true }
    smtp = Mail::SMTP.new(settings).send(:build_smtp_session)
    context = Net::SMTP.default_ssl_context
    context.cert_store = store
    smtp.enable_tls(context)
    smtp
  end

  it 'accepts a trusted IMAP certificate for the original hostname after IP pinning' do
    with_tls_server(:imap) do
      client = imap_client(host)
      expect(client).not_to be_disconnected
    ensure
      client&.disconnect
    end
    expect(Socket).to have_received(:tcp).with(public_ip, 993, connect_timeout: 30).once
    expect(server_names).to eq([host])
  end

  it 'rejects an IMAP certificate for a different hostname' do
    with_tls_server(:imap) do
      expect { imap_client('wrong.example.test') }.to raise_error(OpenSSL::SSL::SSLError)
    end
    expect(server_names).to eq(['wrong.example.test'])
  end

  it 'keeps the trial IMAP sign-in working through the checked socket and TLS hostname' do
    channel = build_stubbed(:channel_email, :imap_email, imap_address: host, imap_authentication: 'login')
    allow(Net::IMAP).to receive(:new).and_wrap_original do |original, name, **options|
      original.call(name, **options, open_timeout: 30, ssl: { cert_store: store, verify_mode: OpenSSL::SSL::VERIFY_PEER })
    end
    verification = Toybaco::Growth::ImapVerification

    with_tls_server(:imap) do
      expect(verification.signed_in?(channel, verification.snapshot(channel))).to be(true)
    end
    expect(imap_commands).to eq(%w[CAPABILITY LOGIN LOGOUT])
    expect(Socket).to have_received(:tcp).with(public_ip, 993, connect_timeout: 30).once
    expect(server_names).to eq([host])
  end

  it 'accepts a trusted SMTP certificate for the original hostname after IP pinning' do
    with_tls_server(:smtp) do
      smtp_client(host).start('fixture.test') { |smtp| expect(smtp).to be_started }
    end
    expect(Socket).to have_received(:tcp).with(public_ip, 465, nil, nil, connect_timeout: 5).once
    expect(TCPSocket).not_to have_received(:open)
    expect(server_names).to eq([host])
  end

  it 'rejects an SMTP certificate for a different hostname' do
    with_tls_server(:smtp) do
      expect { smtp_client('wrong.example.test').start('fixture.test') }.to raise_error(OpenSSL::SSL::SSLError)
    end
    expect(server_names).to eq(['wrong.example.test'])
  end

  %i[imap smtp].each do |protocol|
    it "preserves #{protocol} TLS verification and SNI after an unreachable first address" do
      ipv6 = '2606:4700:4700::1111'
      port = protocol == :imap ? 993 : 465
      allow(Toybaco::Security::MailResolver).to receive(:getaddresses).with(host, timeout: anything).and_return([ipv6, public_ip], ['127.0.0.1'])
      allow(Socket).to receive(:tcp).with(ipv6, port, any_args).and_raise(Errno::ENETUNREACH)

      with_tls_server(protocol) do
        if protocol == :imap
          client = imap_client(host)
          expect(client).not_to be_disconnected
          client.disconnect
        else
          smtp_client(host).start('fixture.test') { |smtp| expect(smtp).to be_started }
        end
      end
      expect(Toybaco::Security::MailResolver).to have_received(:getaddresses).with(host, timeout: anything).once
      expect(Socket).to have_received(:tcp).with(ipv6, port, any_args).once
      expect(Socket).to have_received(:tcp).with(public_ip, port, any_args).once
      expect(server_names).to eq([host])
    end
  end
end
