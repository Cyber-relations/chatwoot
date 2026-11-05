# TODO : Delete this and associated spec once 'api/widget/config' end point is merged
class WidgetsController < ActionController::Base
  include WidgetHelper
  include Toybaco::WidgetPrivacyResponse
  helper_method :http_session_requested?, :legacy_widget_document?

  before_action :set_global_config
  before_action :set_web_widget
  before_action :ensure_account_is_active
  before_action :ensure_location_is_supported
  before_action :retire_legacy_session
  before_action :set_token
  after_action :allow_iframe_requests

  private

  def retire_legacy_session
    return unless request.format.html? && legacy_widget_document?

    response.headers['Clear-Site-Data'] = '"cache"'
    Toybaco::Security::WidgetHttpSession.discard_cookie(request, @web_widget)
  end

  def legacy_widget_document?
    params[:toybaco_sdk] != '2' && params[:toybaco_popout] != '2'
  end

  def set_global_config
    @global_config = GlobalConfig.get(
      'LOGO_THUMBNAIL',
      'BRAND_NAME',
      'WIDGET_BRAND_URL',
      'DIRECT_UPLOADS_ENABLED',
      'MAXIMUM_FILE_UPLOAD_SIZE',
      'INSTALLATION_NAME'
    )
  end

  def set_web_widget
    @web_widget = ::Channel::WebWidget.find_by!(website_token: permitted_params[:website_token])
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error('web widget does not exist')
    render json: { error: 'web widget does not exist' }, status: :not_found
  end

  def set_token
    # Every document is inert, including loads from a cached legacy SDK.
    # Identity is selected only by the same-origin HTTP session bootstrap.
    @token = ''
  end

  def ensure_account_is_active
    raise ActiveRecord::RecordNotFound unless @web_widget.inbox.account.active?
  end

  def ensure_location_is_supported; end

  def permitted_params
    params.permit(:website_token)
  end

  def http_session_requested?
    true
  end

  def allow_iframe_requests
    if @web_widget.allowed_domains.blank? || embedded_from_non_web_origin?
      response.headers.delete('X-Frame-Options')
    else
      domains = @web_widget.allowed_domains.split(',').map(&:strip).join(' ')
      # The public preview and help center embed the SDK on the Chatwoot origin.
      # Keep every configured customer origin while allowing that trusted parent.
      response.headers['Content-Security-Policy'] = "frame-ancestors 'self' #{domains}"
    end
  end

  # Mobile WebViews (iOS/Android) load content from file:// or null origins,
  # which cannot match any domain in frame-ancestors. When the per-inbox flag
  # is enabled, skip frame-ancestors for these requests.
  def embedded_from_non_web_origin?
    return false unless @web_widget.allow_mobile_webview?

    origin = request.headers['Origin']
    origin.blank? || origin == 'null' || origin&.start_with?('file://')
  end
end

WidgetsController.prepend_mod_with('WidgetsController')
