# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # ご契約内容からの解約。LP の「管理画面から2クリック」を期間末解約で実現する。
  # 日割り返金はしない。お支払い方法のポータルとは混ぜない。
  module BillingCancel
    PARAMS = { 'cancel_at_period_end' => 'true' }.freeze

    module_function

    def period_end_params
      PARAMS
    end
  end
end
