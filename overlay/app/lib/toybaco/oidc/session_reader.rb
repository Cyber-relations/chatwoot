# frozen_string_literal: true

# Chatwoot のブラウザcookieから、いま受信箱にログインしている人を割り出す。
# warden / session / cookies.signed はログアウトで確実に消えないため使わず、
# devise_token_auth が保存した bcrypt token と期限を valid_token? で照合する。
class Toybaco::Oidc::SessionReader
  def initialize(cookie_value)
    @cookie_value = cookie_value
  end

  def user
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
    valid_users.first if valid_users.one?
  end

  private

  def parsed_session
    value = JSON.parse(@cookie_value)
    value if value.is_a?(Hash)
  rescue JSON::ParserError, TypeError
    nil
  end
end
