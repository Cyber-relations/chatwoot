# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::InboxesHelper, type: :helper do
  %w[none peer client_once fail_if_no_peer_cert].each do |name|
    it "requires peer and hostname verification for the stored #{name} mode" do
      context = helper.send(:enable_openssl_mode, name)
      expect(context.verify_mode).to eq(OpenSSL::SSL::VERIFY_PEER)
      expect(context.verify_hostname).to be(true)

      settings = { address: 'mail.example.test', port: 465, tls: true, enable_starttls_auto: false,
                   openssl_verify_mode: name, toybaco_public_destination: true }
      smtp = Mail::SMTP.new(settings).send(:build_smtp_session)
      transport_context = smtp.instance_variable_get(:@ssl_context_tls)
      expect(transport_context.verify_mode).to eq(OpenSSL::SSL::VERIFY_PEER)
      expect(transport_context.verify_hostname).to be(true)
      expect_starttls_peer_verification(name)
    end
  end

  ['unrecognized', 'PEER::Object', '', nil, 123].each do |value|
    it "requires peer verification for an invalid or missing mode #{value.inspect}" do
      expect(helper.send(:enable_openssl_mode, value).verify_mode).to eq(OpenSSL::SSL::VERIFY_PEER)
      settings = { address: 'mail.example.test', port: 465, tls: true, enable_starttls_auto: false,
                   openssl_verify_mode: value, toybaco_public_destination: true }
      smtp = Mail::SMTP.new(settings).send(:build_smtp_session)
      expect(smtp.instance_variable_get(:@ssl_context_tls).verify_mode).to eq(OpenSSL::SSL::VERIFY_PEER)
      expect_starttls_peer_verification(value)
    end
  end

  it 'keeps the existing case-insensitive handling of valid modes' do
    expect(helper.send(:enable_openssl_mode, 'PEER').verify_mode).to eq(OpenSSL::SSL::VERIFY_PEER)
  end

  def expect_starttls_peer_verification(value)
    settings = { address: 'mail.example.test', port: 587, tls: false, enable_starttls_auto: true,
                 openssl_verify_mode: value, toybaco_public_destination: true }
    smtp = Mail::SMTP.new(settings).send(:build_smtp_session)
    context = smtp.instance_variable_get(:@ssl_context_starttls)
    expect(context.verify_mode).to eq(OpenSSL::SSL::VERIFY_PEER)
    expect(context.verify_hostname).to be(true)
  end
end
