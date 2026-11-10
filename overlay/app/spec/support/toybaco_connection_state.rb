# frozen_string_literal: true

# The upstream Instagram, TikTok, Linear and Shopify callbacks take only a one-use state that the same signed-in browser
# started (Toybaco::Connections::ProviderOauthState). Sign in through the dashboard browser session and start the
# connection from it, the way the dashboard does.
module ToybacoConnectionStateHelpers
  TOYBACO_CONNECTION_HOST = 'chatwoot.test'

  def toybaco_browser_headers
    { 'X-Toybaco-Browser' => '1', 'Origin' => "https://#{TOYBACO_CONNECTION_HOST}", 'Sec-Fetch-Site' => 'same-origin' }
  end

  # A CSRF token bound to this browser's Rails session, fetched right before each unsafe request.
  def toybaco_csrf_headers
    get '/toybaco/browser-session', headers: toybaco_browser_headers
    raise 'synthetic CSRF token fetch failed' unless response.status == 200

    toybaco_browser_headers.merge('X-CSRF-Token' => response.parsed_body.fetch('csrf_token'))
  end

  def toybaco_browser_sign_in(user)
    host! TOYBACO_CONNECTION_HOST
    https!
    post '/auth/sign_in', params: { email: user.email, password: 'Password1!' }, headers: toybaco_csrf_headers, as: :json
    raise 'synthetic browser sign-in failed' unless response.status == 200
  end

  # Starts a connection of the store from this browser and returns the state in the provider URL.
  def toybaco_start_connection(provider, account, shop: 'sample-store.myshopify.com', return_to: nil)
    case provider
    when 'instagram', 'tiktok'
      post "/api/v1/accounts/#{account.id}/#{provider}/authorization", params: { return_to: return_to }.compact,
                                                                       headers: toybaco_csrf_headers, as: :json
      toybaco_url_state(response.parsed_body['url'])
    when 'linear'
      # The integrations page links the connect button to the Toybaco start, which redirects to Linear with a fresh state.
      get "/api/v1/accounts/#{account.id}/integrations/apps/linear", headers: toybaco_browser_headers
      toybaco_press_linear_connect(response.parsed_body['action'])
    when 'shopify'
      post "/api/v1/accounts/#{account.id}/integrations/shopify/auth", params: { shop_domain: shop },
                                                                       headers: toybaco_csrf_headers, as: :json
      toybaco_url_state(response.parsed_body['redirect_url'])
    end
  end

  def toybaco_press_linear_connect(action)
    raise 'synthetic integrations JSON has no Linear action' unless action.is_a?(String)

    get action, headers: { 'Sec-Fetch-Site' => 'same-origin' }
    raise "synthetic Linear start failed with #{response.status}" unless response.status == 302

    URI.decode_www_form(URI.parse(response.location).query.to_s).to_h.fetch('state')
  end

  def toybaco_url_state(url)
    raise "synthetic connection start failed with #{response.status}" unless response.status == 200 && url.is_a?(String)

    URI.decode_www_form(URI.parse(url).query.to_s).to_h.fetch('state')
  end
end
