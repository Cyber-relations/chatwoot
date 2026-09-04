# frozen_string_literal: true

require_relative 'route_log'
require_relative 'routing_hooks'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # Chatwoot v4.17.1 の ActionMailbox 経路。To が空/不正でも
    # X-Original-To / Delivered-To があれば EmailChannelFinder → SupportMailbox へ載せる。
    module Routing
      include RouteLog
      include RoutingHooks

      RECIPIENT_HEADER_NAMES = %w[X-Original-To Delivered-To X-Forwarded-To].freeze
      FINDER_EXTRA_HEADERS = %w[Delivered-To X-Forwarded-To].freeze

      def mailbox_route(mail, channel_found:)
        return :default unless valid_mailbox_recipients?(mail)
        return :reply if reply_uuid_recipient?(mail)
        return :support if channel_found

        :default
      end

      def valid_mailbox_recipients?(mail)
        mailbox_recipients(mail).any?
      end

      def reply_uuid_recipient?(mail)
        mailbox_recipients(mail).any? do |address|
          local_part, domain = address.split('@', 2)
          REPLY_LOCAL_PART.match?(local_part.to_s) && ALLOWED_DOMAINS.include?(domain)
        end
      end

      def mailbox_recipients(mail)
        values = []
        values.concat(Array(mail_accessor(mail, :to)))
        values.concat(Array(mail_accessor(mail, :cc)))
        RECIPIENT_HEADER_NAMES.each { |name| values.concat(Array(mail_header(mail, name))) }
        values.flatten.compact.map { |value| normalize_address(value) }.uniq.reject(&:empty?)
      end

      def ses_action_mailbox_source(content:, destination:)
        body = crlf(content.to_s)
        dest = normalize_address(destination)
        return body if dest.empty?

        "#{recipient_source_headers(dest)}\r\n#{body}"
      end

      def crlf(text)
        text.to_s.gsub("\r\n", "\n").tr("\r", "\n").gsub("\n", "\r\n")
      end

      def sync_channel_addresses!(channel, address)
        wanted = normalize_address(address)
        raise Rejected, '受信アドレスが不正です' if wanted.empty?

        updates = {}
        updates[:email] = wanted if normalize_address(channel.email) != wanted
        updates[:forward_to_email] = wanted if normalize_address(channel.forward_to_email) != wanted
        channel.update!(updates) unless updates.empty?
        channel
      end

      def install_action_mailbox_hooks!
        install_ses_source_hook!
        install_channel_finder_hook!
      end
    end
  end
end
