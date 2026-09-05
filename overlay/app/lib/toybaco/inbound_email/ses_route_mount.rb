# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # aws-actionmailbox-ses 0.1.0 は routes.append { mount Engine => '/' } し、
    # Engine の config/routes.rb が同じ POST を gem コントローラへ描く。
    # #104 の routes.append は後勝ちせず、先に載った gem 側が 204 だけ返した。
    # 起動時の ERROR 行は toybaco-ses-route-mismatch。
    module SesRouteMount
      def draw_ses_ingress_routes!(mapper)
        return unless ingress_enabled?

        mapper.get INGRESS_PATH, to: INGRESS_GET_TO, as: INGRESS_GET_AS
        mapper.post INGRESS_PATH, to: INGRESS_TO, as: INGRESS_AS
      end

      def register_ses_ingress_route_block!
        return if @ses_ingress_route_block_registered
        return unless defined?(Rails) && Rails.application.respond_to?(:routes)

        @ses_ingress_route_block_registered = true
        Rails.application.routes.prepend do
          Toybaco::InboundEmail.draw_ses_ingress_routes!(self)
        end
      end

      # prepend ブロックは RouteSet 再描画時に再実行される。Engine append の
      # あとに外れていたら reload してから mismatch を出す。
      def ensure_ses_ingress_route!
        return if @ensuring_ses_ingress_route

        @ensuring_ses_ingress_route = true
        register_ses_ingress_route_block!
        return unless ingress_enabled?
        return if ses_ingress_mounted_on_overlay?

        reload_application_routes!
        return if ses_ingress_mounted_on_overlay?

        emit_ses_route_mismatch("expected=#{INGRESS_CONTROLLER} actual=#{recognized_ses_controller}")
      ensure
        @ensuring_ses_ingress_route = false
      end

      def recognized_ses_controller(routes = default_ses_routes)
        return 'missing' unless routes

        routes.recognize_path(INGRESS_PATH, method: :post)[:controller].to_s
      rescue StandardError
        'missing'
      end

      def ses_ingress_mounted_on_overlay?(routes = default_ses_routes)
        overlay_ses_controller?(recognized_ses_controller(routes))
      end

      def warn_unless_ses_route_is_ours!(routes = nil)
        explicit = !routes.nil?
        routes ||= default_ses_routes
        return unless routes
        return unless explicit || ingress_enabled?

        actual = recognized_ses_controller(routes)
        return if overlay_ses_controller?(actual)

        emit_ses_route_mismatch("expected=#{INGRESS_CONTROLLER} actual=#{actual}")
      end

      def emit_ses_route_mismatch(detail)
        line = "#{ROUTE_MISMATCH_PREFIX} #{detail}"
        rails_error_logger&.error(line)
        $stdout.puts(line)
        $stdout.flush
        line
      rescue StandardError
        line
      end

      private

      def overlay_ses_controller?(name)
        [INGRESS_CONTROLLER, INGRESS_TO.split('#').first].include?(name.to_s)
      end

      def default_ses_routes
        return unless defined?(Rails) && Rails.respond_to?(:application)

        Rails.application.routes if Rails.application.respond_to?(:routes)
      end

      def rails_error_logger
        Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)
      end

      def reload_application_routes!
        return unless defined?(Rails) && Rails.application.respond_to?(:reload_routes!)

        Rails.application.reload_routes!
      end
    end
  end
end
