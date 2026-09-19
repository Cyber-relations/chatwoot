# frozen_string_literal: true

require_relative '../../../lib/toybaco/connections/handoff/access'

class Toybaco::ConnectionHandoffPortalController < ActionController::Base # rubocop:disable Rails/ApplicationController
  def show
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
    response.headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; " \
                                                  "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
    return head :not_found unless params[:id].to_s.match?(Toybaco::Connections::Handoff::Access::UUID)
    return head :service_unavailable unless Toybaco::Connections::Handoff::Access.enabled?

    # The page reveals no store identity until the fragment or claimed cookie is verified.
    render template: 'toybaco/connections/handoff_portal', layout: false
  end
end
