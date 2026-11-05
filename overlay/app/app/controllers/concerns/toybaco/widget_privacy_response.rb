# frozen_string_literal: true

module Toybaco::WidgetPrivacyResponse
  extend ActiveSupport::Concern

  included do
    # Run before the inherited widget/session callbacks, so early refusals
    # (for example a missing session proof answered with 404) stay uncached too.
    prepend_before_action :protect_widget_privacy_response
  end

  private

  def protect_widget_privacy_response
    response.headers['Cache-Control'] = 'private, no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
  end
end
