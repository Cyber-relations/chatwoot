# frozen_string_literal: true

require Rails.root.join('lib/toybaco/postiz_origin')
require Rails.root.join('lib/toybaco/dashboard_frame_policy')

# 最外周で応答headerを確定し、controllerや例外画面の経路差で保護が抜けないようにする。
Rails.application.config.middleware.insert_before 0, Toybaco::DashboardFramePolicy
