# frozen_string_literal: true

require_relative 'ops_flag'

# 運営の管理画面(S1-2 以降の運営コンソール)の表示可否。DB flag(TOYBACO_OPS_CONSOLE_ENABLED)が JSON の true の時だけ有効で、
# 既定は無効(未設定・false・文字列の "true" はすべて無効)。切り替えは ops-rake の toybaco:ops_flag で行い、deploy は要らない
# (SuperAdmin の installation_configs 画面は文字列しか保存できないため使わない。ops_flag が書く行は locked: true で画面に出ない)。
# 判定は GlobalConfig の cache を経由せず DB を直接読む(Toybaco::Ops::OpsFlag)。
# 無効の間、画面(SuperAdmin::ToybacoStoresController)は 404 を返し、ナビゲーションにもリンクを出さない。
module Toybaco::Ops::Console
  FLAG = 'TOYBACO_OPS_CONSOLE_ENABLED'

  module_function

  def enabled?
    Toybaco::Ops::OpsFlag.enabled?(FLAG)
  end
end
