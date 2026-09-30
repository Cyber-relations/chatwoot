# frozen_string_literal: true

class Toybaco::BrowserSessionController < ActionController::Base # rubocop:disable Rails/ApplicationController
  def show
    response.headers['Cache-Control'] = 'no-store'
    valid = request.headers['X-Toybaco-Browser'] == '1' &&
            [nil, '', request.base_url].include?(request.headers['Origin']) &&
            [nil, '', 'same-origin'].include?(request.headers['Sec-Fetch-Site'])
    return head :forbidden unless valid

    render json: { csrf_token: form_authenticity_token }
  end
end
