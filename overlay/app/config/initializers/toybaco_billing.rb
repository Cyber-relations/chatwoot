# frozen_string_literal: true

# ご契約内容の解約口。OIDC とは独立して載せる。
Rails.application.routes.append do
  post '/toybaco/billing/cancel', to: 'toybaco/billing#cancel'
end
