# frozen_string_literal: true

Rails.application.routes.append do
  delete '/api/v1/widget/session', to: 'api/v1/widget/sessions#destroy'
end
