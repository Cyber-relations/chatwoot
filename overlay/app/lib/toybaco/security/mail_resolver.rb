# frozen_string_literal: true

require 'resolv'
require 'timeout'

module Toybaco::Security::MailResolver
  def self.getaddresses(host, timeout:)
    raise Resolv::ResolvTimeout, 'Mail DNS timeout' unless timeout.positive?

    # Per-query timeouts alone multiply across search domains, nameservers and
    # A/AAAA queries. The outer limit bounds the entire resolution operation.
    Timeout.timeout(timeout, Resolv::ResolvTimeout, 'Mail DNS timeout') do
      Resolv::DNS.open do |dns|
        dns.timeouts = [timeout]
        Resolv.new([Resolv::Hosts.new, dns]).getaddresses(host)
      end
    end
  end
end
