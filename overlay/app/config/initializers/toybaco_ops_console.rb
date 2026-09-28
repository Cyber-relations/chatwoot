# frozen_string_literal: true

# 運営コンソール(S1-2 店舗一覧)の経路。toybaco_support.rb と同じく routes.append で足す(index と CSV だけ)。
# 表示の可否は DB flag TOYBACO_OPS_CONSOLE_ENABLED(Toybaco::Ops::Console.enabled?、既定 false)で、無効の間は 404。
# administrate のナビゲーションはこの経路を資源として自動では並べない(_navigation.html.erb の除外名簿に載せる)。
Rails.application.routes.append do
  get '/super_admin/toybaco_stores', to: 'super_admin/toybaco_stores#index'
end
