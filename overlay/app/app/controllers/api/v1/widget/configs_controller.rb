class Api::V1::Widget::ConfigsController < Api::V1::Widget::BaseController
  include Toybaco::WidgetPrivacyResponse

  before_action :set_global_config

  def create
    set_token
  end

  private

  def set_global_config
    @global_config = GlobalConfig.get(
      'LOGO_THUMBNAIL',
      'BRAND_NAME',
      'WIDGET_BRAND_URL',
      'MAXIMUM_FILE_UPLOAD_SIZE',
      'INSTALLATION_NAME'
    )
  end

  def set_token
    @token = request.headers['X-Auth-Token'].to_s.start_with?('tbwr1.') ? request.headers['X-Auth-Token'] : @toybaco_http_session.proof
  end
end
