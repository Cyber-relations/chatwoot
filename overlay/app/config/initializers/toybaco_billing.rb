# frozen_string_literal: true

# ご契約内容の解約口。OIDC とは独立して載せる。
Rails.application.routes.append do
  post '/toybaco/billing/cancel', to: 'toybaco/billing#cancel'
  post '/toybaco/billing/change_preview', to: 'toybaco/billing#change_preview'
  post '/toybaco/billing/change_confirm', to: 'toybaco/billing#change_confirm'
  post '/toybaco/billing/change_refresh', to: 'toybaco/billing#change_refresh'
  post '/toybaco/billing/change_cancel', to: 'toybaco/billing#change_cancel'
end
