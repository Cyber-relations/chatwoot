# frozen_string_literal: true

# Authenticate a user socket once with the actual session token, then bind
# every delivered message to its live server record and account membership.
class Toybaco::Security::CableSession
  def initialize(request, user_id, account_id)
    @request = request
    @user_id = user_id.to_s
    @account_id = account_id.to_s
  end

  def authenticate
    return unless valid_ids?

    payload = session_payload
    return unless payload

    reader = Toybaco::Oidc::SessionReader.new(payload.to_json)
    user = reader.user
    return unless user&.id.to_s == @user_id && active_membership?(user)

    @client = payload['client']
    @record_digest = Toybaco::Oidc::SessionReader.record_digest(user, @client)
    return unless @record_digest

    @password_digest = Digest::SHA256.hexdigest(user.encrypted_password)
    user
  end

  def current?
    return false unless @record_digest && @password_digest

    user = User.find_by(id: @user_id)
    return false unless active_membership?(user)

    current_digest = Toybaco::Oidc::SessionReader.record_digest(user, @client)
    current_digest.present? && ActiveSupport::SecurityUtils.secure_compare(current_digest, @record_digest) &&
      ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(user.encrypted_password), @password_digest)
  end

  private

  def valid_ids?
    [@user_id, @account_id].all? { |id| id.match?(/\A[1-9]\d*\z/) }
  end

  def active_membership?(user)
    user&.active_for_authentication? && user.account_users.exists?(account_id: @account_id)
  end

  def session_payload
    cookie = @request.cookies['cw_d_session_info']
    origin = @request.headers['Origin']
    if cookie.present?
      return unless origin == @request.base_url

      payload = JSON.parse(cookie)
      payload if payload.is_a?(Hash)
    else
      # Native WebSocket clients may send explicit DTA headers. A long-lived
      # pubsub_token is a stream identifier, never a login credential.
      native_payload(origin)
    end
  rescue JSON::ParserError
    nil
  end

  def native_payload(origin)
    return if origin.present? && origin != @request.base_url

    %w[access-token client uid].index_with { |key| @request.headers[key] }
  end
end
