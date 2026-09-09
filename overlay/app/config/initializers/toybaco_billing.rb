# frozen_string_literal: true

require_relative '../../lib/toybaco/billing_access'

# ご契約内容の解約口。OIDC とは独立して載せる。
Rails.application.routes.append do
  get '/toybaco/billing/access', to: 'toybaco/billing#access'
  post '/toybaco/billing/cancel', to: 'toybaco/billing#cancel'
  post '/toybaco/billing/change_preview', to: 'toybaco/billing#change_preview'
  post '/toybaco/billing/change_confirm', to: 'toybaco/billing#change_confirm'
  post '/toybaco/billing/change_refresh', to: 'toybaco/billing#change_refresh'
  post '/toybaco/billing/change_cancel', to: 'toybaco/billing#change_cancel'
end

Rails.application.config.to_prepare do
  if ChatwootApp.enterprise?
    controller = Enterprise::Api::V1::AccountsController
    guard = Toybaco::BillingAccess::EnterpriseControllerGuard
    controller.prepend(guard) unless controller < guard
  end
end
