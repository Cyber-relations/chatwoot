# frozen_string_literal: true

require_relative '../../lib/toybaco/checkout'

# セルフサーブ決済: LP のプラン指定を受けて Checkout Session を作る公開口。
Rails.application.routes.append do
  get '/toybaco/checkout', to: 'toybaco/checkout#show'
  post '/toybaco/checkout', to: 'toybaco/checkout#create'
end

# Checkout Session の URL(path の cs_… と fragment)は、その決済の page を開く鍵になる。Rails の "Redirected to" の行には
# [FILTERED] と出す(CASA 6.5.1)。ほかの redirect の行は今のまま。
Rails.application.config.filter_redirect << %r{\Ahttps://checkout\.stripe\.com/}

Rails.application.config.to_prepare do
  next unless defined?(Rack::Attack)

  Rack::Attack.class_eval do
    throttle('toybaco_checkout/ip', limit: 20, period: 1.minute) do |request|
      request.ip if request.path == '/toybaco/checkout'
    end
  end
end
