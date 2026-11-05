# frozen_string_literal: true

# Prepend the shared helper, including its use by ActiveStorage direct uploads.
# PlatformController has a separate PlatformApp-only authentication path.
module Toybaco::Security::PersonalApiAuthentication
  def authenticate_access_token!
    super
    return if performed? || !@resource.is_a?(User)
    return render_unauthorized('Personal API access is disabled') if Toybaco::Security::PersonalApiAccess.blocked?(@resource)
    return unless Toybaco::Security::PersonalApiAccess.mode == 'log'
    return if @toybaco_personal_api_logged

    @toybaco_personal_api_logged = true
    Rails.logger.info({ event: 'toybaco_personal_api_access', user_id: @resource.id,
                        account_id: toybaco_api_account_id, method: request.request_method,
                        path: request.get_header('action_dispatch.route_uri_pattern') || '(unavailable)' }.to_json)
  end

  private

  # Profile/global requests have no account context. Never log query/body values
  # or choose an arbitrary membership for a user who belongs to several stores.
  def toybaco_api_account_id
    field = controller_path == 'api/v1/accounts' ? :id : :account_id
    value = request.path_parameters[field].to_s
    value.to_i if value.match?(/\A[1-9]\d{0,18}\z/)
  end
end
