# frozen_string_literal: true

# 認可コードとアクセストークンだけをRedisへ置き、Rails sessionには状態を残さない。
# 認可コードは60秒・1回限り、userinfo用 token は600秒・複数回参照できる。
class Toybaco::Oidc::CodeStore
  CODE_TTL = 60
  TOKEN_TTL = 600
  CODE_PREFIX = 'TOYBACO_OIDC_CODE::'
  TOKEN_PREFIX = 'TOYBACO_OIDC_TOKEN::'

  class IssueFailed < StandardError; end

  class << self
    def issue_code(user_id:, account_id:, organization_id:, client_id:, redirect_uri:)
      code = SecureRandom.urlsafe_base64(32)
      payload = {
        user_id: user_id,
        account_id: account_id,
        organization_id: organization_id,
        client_id: client_id,
        redirect_uri: redirect_uri,
        exp: Time.current.to_i + CODE_TTL
      }
      stored = Redis::Alfred.set(code_key(code), payload.to_json, nx: true, ex: CODE_TTL)
      raise IssueFailed, '認可コードを保存できません' unless stored

      code
    end

    def consume_code(code)
      return if code.blank?

      parse_json(consume_code_value(code_key(code)))
    end

    def issue_access_token(user_id:, account_id:, organization_id:)
      access_token = SecureRandom.urlsafe_base64(32)
      payload = { user_id: user_id, account_id: account_id, organization_id: organization_id }
      stored = Redis::Alfred.set(token_key(access_token), payload.to_json, nx: true, ex: TOKEN_TTL)
      raise IssueFailed, 'アクセストークンを保存できません' unless stored

      access_token
    end

    def read_access_token(access_token)
      return if access_token.blank?

      parse_json(Redis::Alfred.get(token_key(access_token)))
    end

    private

    # 認可コードは1回しか使えないようにする。
    #
    # GETDEL は使わない。この Redis は redis-namespace を通しており、
    # conn.getdel は接頭辞の付かないキーを見に行ってしまう。例外も出ないまま
    # 「nil を返して削除もしない」ため、コードが常に無効になる(実機で確認済み)。
    # 「読む → 値が変わっていなければ消す」の 1 本に統一する。
    # (GETDEL を先に試す作りにすると、将来 redis-namespace が対応したときに
    #  取得と削除が済んでいるのに読み直す、という食い違いが起きる)
    def consume_code_value(key)
      value = Redis::Alfred.get(key)
      return if value.nil?

      # delete_if_equals は消せたとき [1]、消せなかったとき WATCH 解除の "OK" を返す。
      # どちらも真として扱われるので、「1件消えた」ことを中身で確かめる。
      deleted = Redis::Alfred.delete_if_equals(key, value)
      value if Array(deleted).first.to_i == 1
    end

    def parse_json(value)
      return if value.nil?

      parsed = JSON.parse(value)
      parsed if parsed.is_a?(Hash)
    rescue JSON::ParserError, TypeError
      nil
    end

    def code_key(code)
      "#{CODE_PREFIX}#{code}"
    end

    def token_key(access_token)
      "#{TOKEN_PREFIX}#{access_token}"
    end
  end
end
