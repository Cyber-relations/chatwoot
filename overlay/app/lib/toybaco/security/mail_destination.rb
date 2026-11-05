# frozen_string_literal: true

require 'ssrf_filter'
require_relative 'mail_resolver'

module Toybaco::Security::MailDestination
  PORTS = [25, 465, 587, 2525, 143, 993].freeze
  ERROR = 'Mail destination must use a public address and an allowed mail port'
  SAVE_DNS_TIMEOUT = 1
  CONNECT_DNS_TIMEOUT = 30

  def self.validate!(host, port)
    raise SocketError, ERROR unless port.blank? || PORTS.include?(Integer(port.to_s, 10))
    return if host.blank?

    # Saving configuration does not require DNS availability. Every connection
    # resolves once through resolve_all!, requiring a wholly public address set.
    addresses = addresses_for_validation(host.to_s.strip)
    raise SocketError, ERROR if addresses.any? { |address| unsafe?(address) }
  rescue ArgumentError
    raise SocketError, ERROR
  end

  def self.resolve!(host, port)
    resolve_all!(host, port).first
  end

  def self.resolve_all!(host, port, timeout: CONNECT_DNS_TIMEOUT)
    hostname = host.to_s.strip
    raise SocketError, ERROR unless PORTS.include?(Integer(port.to_s, 10))

    validate_hostname!(hostname)

    addresses = addresses_for(hostname, timeout: timeout)
    raise SocketError, ERROR if addresses.empty? || addresses.any? { |address| unsafe?(address) }

    addresses.map(&:to_s).uniq.freeze
  rescue ArgumentError, Resolv::ResolvError
    raise SocketError, ERROR
  end

  def self.validate_hostname!(hostname)
    raise SocketError, ERROR if hostname.blank? || hostname.match?(%r{[\s/@%?#]})
  end
  private_class_method :validate_hostname!

  def self.addresses_for(host, timeout:)
    [IPAddr.new(host).native]
  rescue IPAddr::InvalidAddressError
    Toybaco::Security::MailResolver.getaddresses(host, timeout: timeout).map { |address| IPAddr.new(address).native }
  end

  def self.addresses_for_validation(host)
    addresses_for(host, timeout: SAVE_DNS_TIMEOUT)
  rescue Resolv::ResolvError, Resolv::ResolvTimeout, SocketError
    []
  end

  def self.unsafe?(address)
    # Reuse the pinned SafeFetch/avatar/webhook policy, including mapped IPv6.
    # Azure's platform virtual address is public-looking but not a mail destination.
    address.to_i.zero? || address.to_s == '168.63.129.16' || SsrfFilter.send(:unsafe_ip_address?, address)
  end
end
