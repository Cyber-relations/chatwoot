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

      # gem コントローラへの prepend は backup。正本は overlay の
      # Toybaco::SesInboundEmailsController が RouteSet から直接 create する。
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

      SES_INGRESS_CONTROLLER_NAMES = [
        'ActionMailbox::Ingresses::Ses::InboundEmailsController',
        'ActionMailbox::Ingresses::Ses::InboundEmails'
      ].freeze
      SES_INGRESS_CONTROLLER_RELATIVE =
        'app/controllers/action_mailbox/ingresses/ses/inbound_emails_controller.rb'

      # ActionMailbox::RoutingJob#perform は staging で既に CW に出ている経路。
      module RoutingJobRouteLog
        def perform(inbound_email)
          super
        ensure
          emit_toybaco_routing_job_route(inbound_email)
        end

        private

        def emit_toybaco_routing_job_route(inbound_email)
          source = if inbound_email.respond_to?(:source)
                     inbound_email.source
                   else
                     inbound_email
                   end
          Toybaco::InboundEmail.log_ses_create_route(source: source.to_s)
        rescue StandardError
          nil
        end
      end

      def load_ses_ingress_controller!
        found = ses_ingress_controller_class
        return found if found

        require 'aws/action_mailbox/ses'
        spec = Gem.loaded_specs['aws-actionmailbox-ses']
        if spec
          path = File.join(spec.full_gem_path, SES_INGRESS_CONTROLLER_RELATIVE)
          require path if File.file?(path)
        end
        ses_ingress_controller_class
      rescue LoadError, NameError
        ses_ingress_controller_class
      end

      def ses_ingress_controller_class
        SES_INGRESS_CONTROLLER_NAMES.each do |name|
          found = constantize_without_autoload(name)
          return found if found.is_a?(Class)
        end
        nil
      end

      def install_inbound_email_create_hook!
        return unless defined?(ActionMailbox) && ActionMailbox.const_defined?(:InboundEmail)

        owner = ActionMailbox::InboundEmail.singleton_class
        return if owner <= CreateAndExtractMessageId

        owner.prepend(CreateAndExtractMessageId)
      end

      def install_ses_ingress_create_hook!
        klass = load_ses_ingress_controller!
        unless klass
          emit_ses_route_mismatch('controller_missing')
          return
        end

        klass.class_eval do
          hook = Toybaco::InboundEmail::RoutingHooks::SesCreateRouteLog
          prepend hook unless self < hook
        end
      end

      def install_routing_job_hook!
        return unless defined?(ActionMailbox) && ActionMailbox.const_defined?(:RoutingJob)

        klass = ActionMailbox::RoutingJob
        return if klass < RoutingJobRouteLog

        klass.prepend(RoutingJobRouteLog)
      end

      def constantize_without_autoload(name)
        name.split('::').reduce(Object) do |mod, part|
          return nil unless mod.is_a?(Module) && mod.const_defined?(part, false)

          mod.const_get(part, false)
        end
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
