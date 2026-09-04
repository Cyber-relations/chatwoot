# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # gem 0.1.0 は inline だけ X-Original-To を LF で足す。S3 原本にも
    # envelope 宛先を CRLF で載せ、finder が shop-1 SES 経路を拾えるようにする。
    module RoutingHooks
      module SesSource
        def message_content
          klass = Aws::ActionMailbox::SES::SNSNotification
          raise klass::MessageContentError, 'Incoming emails must have notificationType `Received`' unless receipt?

          content = content_in_s3? ? s3_content : message[:content]
          Toybaco::InboundEmail.ses_action_mailbox_source(
            content: content,
            destination: destination
          )
        end
      end

      module ChannelFinderRecipients
        private

        def primary_recipient_emails
          headers = %w[X-Original-To] + Toybaco::InboundEmail::Routing::FINDER_EXTRA_HEADERS
          extras = headers.flat_map do |name|
            field = @email_object[name]
            raw = field.respond_to?(:value) ? field.value : field
            Array(raw)
          end
          values = (Array(@email_object.to) + Array(@email_object.cc) + extras).flatten.compact
          values.map { |value| Toybaco::InboundEmail.normalize_address(value) }.uniq.reject(&:empty?)
        end
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

      module CreateAndExtractMessageId
        def create_and_extract_message_id!(source, **)
          super
        ensure
          Toybaco::InboundEmail.log_ses_create_route(source: source)
        end
      end

      # aws-actionmailbox-ses 0.1.0 の create が 204 を返す過程。
      # create_and_extract_message_id! への prepend は defined? で黙って
      # 外れるので、コントローラ action 側でも同じ1行を出す。
      module SesCreateRouteLog
        def create
          super
        ensure
          emit_toybaco_ses_create_route
        end

        private

        def emit_toybaco_ses_create_route
          return unless response&.status == 204

          Toybaco::InboundEmail.log_ses_create_route(source: toybaco_ses_create_source)
        end

        def toybaco_ses_create_source
          notification.message_content.to_s
        rescue StandardError
          request&.raw_post.to_s
        end
      end

      def install_inbound_email_create_hook!
        owner = ActionMailbox::InboundEmail.singleton_class
        return if owner <= CreateAndExtractMessageId

        owner.prepend(CreateAndExtractMessageId)
      rescue NameError
        nil
      end

      def install_ses_ingress_create_hook!
        klass = ActionMailbox::Ingresses::Ses::InboundEmailsController
        return if klass < SesCreateRouteLog

        klass.prepend(SesCreateRouteLog)
      rescue NameError
        nil
      end

      private

      def recipient_source_headers(destination)
        ["X-Original-To: #{destination}", "Delivered-To: #{destination}"].join("\r\n")
      end
    end
  end
end
