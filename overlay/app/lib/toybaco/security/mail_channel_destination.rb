# frozen_string_literal: true

module Toybaco::Security::MailChannelDestination
  def self.prepended(base)
    base.validate :toybaco_validate_mail_destinations
  end

  private

  def toybaco_validate_mail_destinations
    %w[imap smtp].each { |protocol| toybaco_validate_mail_destination(protocol) }
  end

  def toybaco_validate_mail_destination(protocol)
    address = "#{protocol}_address"
    port = "#{protocol}_port"
    enabled = "#{protocol}_enabled"
    return unless changed_attribute_names_to_save.any? { |attribute| attribute.start_with?("#{protocol}_") }
    return unless self[enabled]

    # Upstream permits an incomplete enabled channel (blank host, default port 0).
    return if toybaco_incomplete_mail_destination?(address, port)

    Toybaco::Security::MailDestination.validate!(self[address], self[port])
  rescue SocketError
    errors.add(address, Toybaco::Security::MailDestination::ERROR)
  end

  def toybaco_incomplete_mail_destination?(address, port)
    self[address].blank? && self[port]&.zero?
  end
end
