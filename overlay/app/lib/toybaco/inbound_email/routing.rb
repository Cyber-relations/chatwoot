# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # Chatwoot v4.17.1 の ActionMailbox 経路。To が空/不正でも
    # X-Original-To / Delivered-To があれば EmailChannelFinder → SupportMailbox へ載せる。
    module Routing
      RECIPIENT_HEADER_NAMES = %w[X-Original-To Delivered-To X-Forwarded-To].freeze
      FINDER_EXTRA_HEADERS = %w[Delivered-To X-Forwarded-To].freeze
      MAILBOX_LOG_NAMES = %w[SupportMailbox ReplyMailbox DefaultMailbox].freeze
      MESSAGE_ID = /\A<?[^\s<>]{1,200}>?\z/

      def mailbox_route(mail, channel_found:)
        return :default unless valid_mailbox_recipients?(mail)
        return :reply if reply_uuid_recipient?(mail)
        return :support if channel_found

        :default
      end

      def valid_mailbox_recipients?(mail)
        return false if malformed_to?(mail)

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

      def mailbox_route_log(mailbox:, message_id:, conversation: nil)
        name = MAILBOX_LOG_NAMES.include?(mailbox.to_s) ? mailbox.to_s : 'DefaultMailbox'
        mid = sanitize_message_id(message_id)
        parts = ["Toybaco inbound route mailbox=#{name}"]
        parts << (conversation ? 'Conversation=yes' : 'Conversation=no') unless conversation.nil?
        parts << "message_id=#{mid}"
        parts.join(' ')
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

      module SesSource
        def message_content
          klass = Aws::ActionMailbox::SES::SNSNotification
          raise klass::MessageContentError, 'Incoming emails must have notificationType `Received`' unless receipt?
          return s3_content if content_in_s3?

          Toybaco::InboundEmail.ses_action_mailbox_source(
            content: message[:content],
            destination: destination
          )
        end
      end

      module ChannelFinderRecipients
        private

        def primary_recipient_emails
          headers = %w[X-Original-To] + Toybaco::InboundEmail::Routing::FINDER_EXTRA_HEADERS
          extras = headers.map do |name|
            field = @email_object[name]
            field.respond_to?(:value) ? field.value : field
          end
          (Array(@email_object.to) + Array(@email_object.cc) + extras).flatten.compact
        end
      end

      private

      def malformed_to?(mail)
        mail_accessor(mail, :to).is_a?(String)
      end

      def mail_accessor(mail, key)
        if mail.respond_to?(key)
          mail.public_send(key)
        elsif mail.is_a?(Hash)
          mail[key] || mail[key.to_s]
        end
      end

      def mail_header(mail, name)
        if mail.respond_to?(:[])
          field = mail[name]
          return field.value if field.respond_to?(:value)

          field
        elsif mail.is_a?(Hash)
          mail[name] || mail[name.to_s]
        end
      end

      def recipient_source_headers(destination)
        ["X-Original-To: #{destination}", "Delivered-To: #{destination}"].join("\r\n")
      end

      def sanitize_message_id(value)
        text = value.to_s.strip
        return 'unavailable' unless MESSAGE_ID.match?(text)

        text
      end

      def install_ses_source_hook!
        return unless defined?(Aws::ActionMailbox::SES::SNSNotification)
        return if Aws::ActionMailbox::SES::SNSNotification <= SesSource

        Aws::ActionMailbox::SES::SNSNotification.prepend(SesSource)
      end

      def install_channel_finder_hook!
        return unless defined?(EmailChannelFinder)
        return if EmailChannelFinder <= ChannelFinderRecipients

        EmailChannelFinder.prepend(ChannelFinderRecipients)
      end
    end
  end
end
