# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # 起動時に1行だけ出し、digest が hook を積んだか診断で区別する。
    # 一意部分は toybaco-inbound-hooks-loaded=e148640e9ee1。
    module SesIngressBoot
      HOOKS_LOADED_MARK = 'toybaco-inbound-hooks-loaded'
      HOOKS_LOADED_SHA = 'e148640e9ee1'
      HOOKS_LOADED_LINE = "#{HOOKS_LOADED_MARK}=#{HOOKS_LOADED_SHA}".freeze

      def emit_inbound_hooks_loaded_banner!
        return if @inbound_hooks_loaded_banner_emitted

        @inbound_hooks_loaded_banner_emitted = true
        emit_cloudwatch_line(HOOKS_LOADED_LINE)
        HOOKS_LOADED_LINE
      rescue StandardError
        HOOKS_LOADED_LINE
      end
    end
  end
end
