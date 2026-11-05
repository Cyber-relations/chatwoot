# frozen_string_literal: true

require 'timeout'

module Toybaco::Security::MailSocketGuard
  CONNECT_TIMEOUT = 30

  private

  def tcp_socket(host, port)
    # Only replace the TCP destination. Net::IMAP @host / Net::SMTP @address
    # retain the original hostname for TLS SNI and certificate verification.
    budget = open_timeout ? [open_timeout, CONNECT_TIMEOUT].min : CONNECT_TIMEOUT
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + budget
    addresses = resolve_mail_addresses(host, port, deadline)
    connect_mail_addresses(addresses, deadline) { |address| super(address, port) }
  end

  def resolve_mail_addresses(host, port, deadline)
    Toybaco::Security::MailDestination.resolve_all!(host, port, timeout: remaining_mail_time(deadline))
  rescue Resolv::ResolvTimeout
    raise Net::OpenTimeout, 'Mail connection timeout'
  end

  def remaining_mail_time(deadline)
    remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise Net::OpenTimeout, 'Mail connection timeout' unless remaining.positive?

    remaining
  end

  def connect_mail_addresses(addresses, deadline)
    addresses.each_with_index do |address, index|
      remaining = remaining_mail_time(deadline)

      begin
        # Reserve time for every checked candidate, including IPv4 after an
        # unreachable IPv6 address. Never hand the hostname back to the resolver.
        return Timeout.timeout(remaining / (addresses.length - index), Net::OpenTimeout) { yield address }
      rescue SystemCallError, SocketError, Net::OpenTimeout
        raise if index == addresses.length - 1
      end
    end
  end
end
