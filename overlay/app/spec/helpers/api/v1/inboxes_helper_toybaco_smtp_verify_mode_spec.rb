# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::InboxesHelper, type: :helper do
  {
    'none' => OpenSSL::SSL::VERIFY_NONE,
    'peer' => OpenSSL::SSL::VERIFY_PEER,
    'client_once' => OpenSSL::SSL::VERIFY_CLIENT_ONCE,
    'fail_if_no_peer_cert' => OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
  }.each do |name, value|
    it "preserves the #{name} mode" do
      expect(helper.send(:enable_openssl_mode, name).verify_mode).to eq(value)
    end
  end

  ['unrecognized', 'PEER::Object', '', nil, 123].each do |value|
    it "falls back to the current none default for #{value.inspect}" do
      expect(helper.send(:enable_openssl_mode, value).verify_mode).to eq(OpenSSL::SSL::VERIFY_NONE)
    end
  end

  it 'keeps the existing case-insensitive handling of valid modes' do
    expect(helper.send(:enable_openssl_mode, 'PEER').verify_mode).to eq(OpenSSL::SSL::VERIFY_PEER)
  end
end
