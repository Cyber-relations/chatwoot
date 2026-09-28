# frozen_string_literal: true

# 運営の管理画面(S1-2 以降の運営コンソール)の表示可否。DB flag(TOYBACO_OPS_CONSOLE_ENABLED)が JSON の true の時だけ有効で、
# 既定は無効(未設定・false・文字列の "true" はすべて無効)。SuperAdmin 設定で切り替え、deploy は要らない。
# 無効の間、画面(SuperAdmin::ToybacoStoresController)は 404 を返し、ナビゲーションにもリンクを出さない。
module Toybaco::Ops::Console
  FLAG = 'TOYBACO_OPS_CONSOLE_ENABLED'

  module_function

  def enabled?
    GlobalConfigService.load(FLAG, false) == true
  end
end
