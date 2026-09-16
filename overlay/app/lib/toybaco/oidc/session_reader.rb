# frozen_string_literal: true

require 'digest/sha2'

# Chatwoot のブラウザcookieから、いま受信箱にログインしている人を割り出す。
# warden / session / cookies.signed はログアウトで確実に消えないため使わず、
# devise_token_auth が保存した bcrypt token と期限を valid_token? で照合する。
class Toybaco::Oidc::SessionReader
  def initialize(cookie_value)
    @cookie_value = cookie_value
  end

  def user
    @validated_user = @validated_client = @validated_at = nil
    session = parsed_session
    return unless session

    access_token, client, uid = session.values_at('access-token', 'client', 'uid')
    return unless [access_token, client, uid].all?(&:present?)

    # js-cookie が値に残す生の + は Rack で空白に復号されるため、復元候補も検索する。
    # uid(email) は変更・重複し得るため一意キーとは扱わず、候補をすべて bcrypt 照合し、
    # 現在の client token が exactly 1 人だけに有効な場合に限る。
    # 0 人だけでなく複数一致も fail closed にし、Postiz の sub には User ID を使う。
    uid_candidates = [uid, uid.tr(' ', '+')].uniq
    valid_users = User.where(uid: uid_candidates).to_a.select do |candidate|
      candidate.confirmed? && candidate.valid_token?(access_token, client)
    end
    return unless valid_users.one?

    @validated_user = valid_users.first
    @validated_client = client
    @validated_at = Time.current.to_i
    @validated_user
  end

  # Renewal carries only server-record identity, never the browser's bearer token.
  def renewal_binding(user)
    return unless user == @validated_user && @validated_at

    digest = self.class.record_digest(user, @validated_client)
    return unless digest

    { 'client' => @validated_client, 'record_digest' => digest, 'auth_time' => @validated_at }
  end

  def self.renewal_current?(user, binding)
    return false unless valid_binding?(binding) && current_auth_time?(binding['auth_time'])

    current = record_digest(user, binding['client'])
    current.present? && ActiveSupport::SecurityUtils.secure_compare(current, binding['record_digest'])
  end

  def self.record_digest(user, client)
    return unless user&.confirmed? && client.is_a?(String) && client.present? && client.length <= 200

    record = user.tokens[client] if user.tokens.is_a?(Hash)
    return unless valid_record?(record)

    # Current-token rotation deliberately fails renewal closed. Batch timestamps
    # and last_token are excluded: ordinary reads must not invalidate the binding.
    Digest::SHA256.hexdigest([record['token'], record['expiry']].to_json)
  end

  def self.valid_binding?(binding)
    binding.is_a?(Hash) && binding.keys.sort == %w[auth_time client record_digest] &&
      binding['record_digest'].is_a?(String) && binding['record_digest'].match?(/\A[0-9a-f]{64}\z/)
  end

  def self.current_auth_time?(auth_time)
    now = Time.current.to_i
    auth_time.is_a?(Integer) && auth_time.positive? && auth_time <= now && now < auth_time + 600
  end

  def self.valid_record?(record)
    record.is_a?(Hash) && record['token'].is_a?(String) && record['token'].present? &&
      record['expiry'].is_a?(Integer) && record['expiry'] > Time.current.to_i
  end

  private_class_method :valid_binding?, :current_auth_time?, :valid_record?

  private

  def parsed_session
    value = JSON.parse(@cookie_value)
    value if value.is_a?(Hash)
  rescue JSON::ParserError, TypeError
    nil
  end
end
