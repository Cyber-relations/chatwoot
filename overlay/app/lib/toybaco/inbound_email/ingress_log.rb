# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # SES ingress の create_and_extract_message_id! は 204 と同じ Rails 過程。
    # 原本 source から token 付き経路ログを出し、RoutingJob 待ちにしない。
    module IngressLog
      def log_ingress_mailbox_route(source, channel_found: nil)
        raw = source.to_s
        mail = ingress_mail_from(raw)
        found = channel_found.nil? ? ingress_channel_found?(mail) : channel_found
        route = mailbox_route(mail, channel_found: found)
        line = log_mailbox_route(
          mail,
          mailbox: ingress_mailbox_name(route),
          conversation: false,
          raw: raw
        )
        rails_info(line)
        line
      rescue StandardError
        nil
      end

      private

      def ingress_mail_from(raw)
        return ::Mail.new(raw) if defined?(::Mail)

        {
          :raw_source => raw,
          :to => header_field(raw, 'To'),
          :cc => header_field(raw, 'Cc'),
          'X-Original-To' => header_field(raw, 'X-Original-To'),
          'Delivered-To' => header_field(raw, 'Delivered-To'),
          'X-Forwarded-To' => header_field(raw, 'X-Forwarded-To'),
          'X-Toybaco-Fixture' => header_field(raw, 'X-Toybaco-Fixture'),
          :message_id => extract_header_message_id(raw)
        }
      end

      def ingress_channel_found?(mail)
        return false unless defined?(EmailChannelFinder)

        EmailChannelFinder.new(mail).perform.present?
      rescue StandardError
        false
      end

      def ingress_mailbox_name(route)
        case route
        when :support then 'SupportMailbox'
        when :reply then 'ReplyMailbox'
        else 'DefaultMailbox'
        end
      end

      def rails_info(line)
        return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

        Rails.logger.info(line)
      end
    end
  end
end
