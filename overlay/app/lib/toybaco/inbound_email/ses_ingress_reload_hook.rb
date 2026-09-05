# frozen_string_literal: true

require_relative 'ses_ingress_reload_helpers'
require_relative 'ses_ingress_log_subscriber'
require_relative 'ses_ingress_process_action'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # #108 の AC LogSubscriber prepend は lograge が購読を外すと 0 行。
    # 正本は Lograge subscriber / start_processing（params が既に CW に出る口）。
    module SesIngressReloadHook
      include SesIngressReloadHelpers
      include SesIngressProcessAction

      PROCESS_ACTION_EVENT = SesIngressProcessAction::PROCESS_ACTION_EVENT
      # RoutingHooks の同名定数は兄弟モジュールなので、ここからは見えない。
      # boot の Zeitwerk on_load は自モジュールの定数を使う。
      SES_INGRESS_CONTROLLER_NAMES = [
        'ActionMailbox::Ingresses::Ses::InboundEmailsController',
        'ActionMailbox::Ingresses::Ses::InboundEmails'
      ].freeze

      def install_ses_ingress_reload_hooks!
        install_ses_log_subscriber_hook!
        watch_zeitwerk_ses_classes!
        register_ses_reloader_hook!
        Toybaco::InboundEmail.reapply_ses_ingress_wrappers!
      end

      # Reloader / Zeitwerk は block を別 self で instance_exec する。
      # 裸の reapply_ses_ingress_wrappers! は NoMethodError になる。
      def register_ses_reloader_hook!
        return if @ses_reloader_hook_registered
        return unless defined?(ActiveSupport::Reloader) && ActiveSupport::Reloader.respond_to?(:to_prepare)

        @ses_reloader_hook_registered = true
        ActiveSupport::Reloader.to_prepare do
          Toybaco::InboundEmail.reapply_ses_ingress_wrappers!
        end
      end

      def reapply_ses_ingress_wrappers!
        load_ses_ingress_controller!
        install_ses_source_hook!
        install_channel_finder_hook!
        install_inbound_email_create_hook!
        install_ses_ingress_create_hook!
        install_routing_job_hook!
        Toybaco::InboundEmail.install_ses_log_subscriber_hook!
        Toybaco::InboundEmail.install_ses_lograge_hook!
      end

      def zeitwerk_ses_class_names
        (
          SesIngressReloadHook::SES_INGRESS_CONTROLLER_NAMES +
            [Toybaco::InboundEmail::INGRESS_SES_CONTROLLER] +
            %w[ActionMailbox::RoutingJob ActionMailbox::InboundEmail]
        ).uniq
      end

      private

      def watch_zeitwerk_ses_classes!
        return unless defined?(Rails) && Rails.respond_to?(:autoloaders)

        names = zeitwerk_ses_class_names
        Rails.autoloaders.each do |loader|
          next unless loader.respond_to?(:on_load)

          names.each do |name|
            loader.on_load(name) { Toybaco::InboundEmail.reapply_ses_ingress_wrappers! }
          end
        end
      end
    end
  end
end
