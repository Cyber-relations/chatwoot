# frozen_string_literal: true

class Toybaco::WidgetPreviewsController < ApplicationController
  before_action :set_preview_headers

  def show
    token = params[:website_token]
    return head :not_found unless token.is_a?(String) && token.present?

    @web_widget = Channel::WebWidget.find_by(website_token: token)
    return head :not_found unless @web_widget&.inbox&.account&.active?

    render :show, layout: false
  end

  private

  def set_preview_headers
    response.headers['X-Robots-Tag'] = 'noindex, nofollow'
    response.headers['Content-Security-Policy'] = "frame-ancestors 'none'"
    response.headers['X-Frame-Options'] = 'DENY'
    response.headers['Cache-Control'] = 'private, no-store'
  end
end
