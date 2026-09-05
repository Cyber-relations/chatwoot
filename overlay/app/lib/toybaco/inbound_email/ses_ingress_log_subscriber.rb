# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # start_processing は Parameters 行（token が既に CW に出る口）を書く。
    # process_action の Completed 204 は token を含まず、lograge 時は購読自体が無い。
    module SesIngressLogSubscriber
      def start_processing(event)
        super
        emit_toybaco_ses_visible_route(event)
      end

      def process_action(event)
        super
        emit_toybaco_ses_visible_route(event)
      end

      def emit_toybaco_ses_visible_route(event)
        logger_ref = respond_to?(:logger) ? logger : nil
        Toybaco::InboundEmail.emit_ses_route_from_process_action(event, logger: logger_ref)
      end
    end
  end
end
