# frozen_string_literal: true

require 'digest/sha1'

# Chatwoot を認証・所属の正本として、Postiz 側の利用者と所属を同期する。
#
# 認可コードを発行する前と、権限を剥奪するトランザクションの途中で呼ばれるため、
# 失敗を握りつぶしてはならない。Postiz の DB が利用できない場合は呼び出し元を失敗させ、
# 「Chatwoot では退会済みだが Postiz の古いセッションは利用可能」という状態を作らない。
class Toybaco::PostizSync # rubocop:disable Metrics/ClassLength
  ROLE_MAP = {
    'administrator' => 'ADMIN',
    'agent' => 'USER'
  }.freeze

  # account_id / user_id から再計算できる UUID v5。Chatwoot 側への mapping 保存が
  # INSERT 後に失敗しても、次回は同じ Postiz 行へ収束する。
  ORGANIZATION_NAMESPACE = '2ce137d1-b153-5df8-a334-f97cb11ad413'
  USER_NAMESPACE = 'c2b69454-2577-5ca4-a2ed-b06c9909691a'
  POSTIZ_ADVISORY_LOCK_NAMESPACE = 1_415_139_403
  CHATWOOT_USER_LOCK_NAMESPACE = 1_415_139_404
  CHATWOOT_ACCOUNT_LOCK_NAMESPACE = 1_415_139_405

  class Error < StandardError; end
  class NotConfigured < Error; end
  class Unavailable < Error; end
  class Ineligible < Error; end
  class IdentityConflict < Error; end
  class MappingConflict < Error; end
  class AccessRevoked < Error; end

  class << self
    def configured?
      ENV['TOYBACO_POSTIZ_DATABASE_URL'].present?
    end

    def enabled?(account)
      account&.internal_attributes&.dig('postiz', 'enabled') == true
    end

    def managed?(account)
      enabled?(account) || organization_id_for(account).present?
    end

    # JIT 同期は必ず active account の現行 AccountUser を根拠にする。
    # 成功時に返す organization_id だけが OIDC code/token/userinfo の trusted claim になる。
    def sync!(user:, account:)
      require_configuration!

      # Chatwoot 側の transaction advisory lock を Postiz commit まで保持する。
      # offboarding と同時に authorize が走っても、削除前の所属を読んで
      # revoke 後に再有効化する競合を防ぐ。
      with_chatwoot_identity_locks(user_id: user.id, account_ids: [account.id]) do
        sync_under_identity_lock(user.id, account.id)
      end
    end

    # OIDC token/userinfo は発行済み token の内容だけを信用せず、毎回両 DB を再検証する。
    def access_context(user:, account:, organization_id:)
      require_configuration!
      account_user = eligible_account_user(user, account)
      raise AccessRevoked, 'Chatwoot の有効な所属がありません' unless account_user
      raise AccessRevoked, 'Postiz organization が一致しません' unless trusted_organization?(account, organization_id)

      role = mapped_role!(account_user, AccessRevoked)
      row = verify_access!(user.id, organization_id, role)
      { organization_id: organization_id, user_id: row.fetch('user_id'), role: role }
    end

    # AccountUser destroy の前に呼ぶ。Postiz JWT は毎リクエスト DB を引き直すため、
    # membership.disabled=true が既存ブラウザセッションの即時失効点になる。
    def revoke_membership!(user_id:, account:, force: false)
      return :not_managed unless force || managed?(account)

      require_configuration!
      with_chatwoot_identity_locks(user_id: user_id, account_ids: [account.id]) do
        organization_id = trusted_organization_id!(account, MappingConflict)
        with_transaction do
          lock_account!(account.id)
          revoke_user_from_organization!(user_id, organization_id, disable_membership: true)
        end
      end
      :revoked
    end

    # administrator -> agent の変更は Chatwoot commit より先に権限を落とす。
    # 逆方向の昇格は commit 後の sync! だけで行い、rollback 時の過剰付与を防ぐ。
    def demote_membership!(user_id:, account:, force: false)
      return :not_managed unless force || managed?(account)

      require_configuration!
      with_chatwoot_identity_locks(user_id: user_id, account_ids: [account.id]) do
        organization_id = trusted_organization_id!(account, MappingConflict)
        with_transaction do
          lock_account!(account.id)
          revoke_user_from_organization!(user_id, organization_id, disable_membership: false)
        end
      end
      :demoted
    end

    # Account suspended / postiz.enabled=false / Account destroy の前に呼ぶ。
    def disable_account!(account:, force: false)
      return :not_managed unless force || managed?(account)

      require_configuration!
      with_chatwoot_identity_locks(account_ids: [account.id]) do
        organization_id = trusted_organization_id!(account, MappingConflict)
        with_transaction do
          lock_account!(account.id)
          exec(
            <<~SQL.squish,
              UPDATE "UserOrganization"
                 SET disabled = true, "updatedAt" = NOW()
               WHERE "organizationId" = $1
            SQL
            [organization_id]
          )
          revoke_organization_credentials!(organization_id)
          deactivate_users_without_memberships!(organization_id)
        end
      end
      :disabled
    end

    # User 自体を削除する経路でも、destroy_async の AccountUser を待たずに全所属を閉じる。
    def disable_user!(user_id:)
      require_configuration!
      provider_id = provider_id_for(user_id)

      with_chatwoot_identity_locks(user_id: user_id) do
        with_transaction do
          disable_memberships_for_provider!(provider_id)
          deactivate_provider_user!(provider_id)
        end
      end
      :disabled
    end

    def organization_id_for(account)
      account&.internal_attributes&.dig('postiz', 'organization_id')
    end

    def deterministic_organization_id(account_id)
      uuid_v5(ORGANIZATION_NAMESPACE, "chatwoot-account:#{Integer(account_id)}")
    end

    def deterministic_user_id(user_id)
      uuid_v5(USER_NAMESPACE, "chatwoot-user:#{Integer(user_id)}")
    end

    private

    def sync_under_identity_lock(user_id, account_id)
      user = User.find_by(id: user_id)
      account = Account.find_by(id: account_id)
      account_user = eligible_account_user(user, account)
      raise Ineligible, 'Chatwoot の有効な所属がありません' unless account_user
      raise Ineligible, 'メールアドレスが空です' if user.email.blank?

      # internal_attributes は運用上の記録であり認可根拠ではない。常に Chatwoot
      # account id から再計算し、保存値が別 tenant を指す場合は Postiz を一切触らず止める。
      organization_id = trusted_organization_id!(account, MappingConflict)
      role = mapped_role!(account_user, Ineligible)
      postiz_user_id = sync_postiz_rows(user, account, organization_id, role)

      # 外部 DB commit 後に保存が失敗しても、決定的 ID で次回回収できる。
      remember_organization(account, organization_id)
      { organization_id: organization_id, user_id: postiz_user_id, role: role }
    end

    def sync_postiz_rows(user, account, organization_id, role)
      postiz_user_id = nil
      with_transaction do
        lock_account!(account.id)
        ensure_organization(account, organization_id)
        postiz_user_id = ensure_user(user)
        ensure_membership(postiz_user_id, organization_id, role)
        verify_access!(user.id, organization_id, role)
      end
      postiz_user_id
    end

    def require_configuration!
      raise NotConfigured, 'TOYBACO_POSTIZ_DATABASE_URL が設定されていません' unless configured?
    end

    def eligible_account_user(user, account)
      return unless user && account&.active? && enabled?(account)

      AccountUser.find_by(user_id: user.id, account_id: account.id)
    end

    def trusted_organization?(account, organization_id)
      organization_id.present? && organization_id == trusted_organization_id!(account, AccessRevoked)
    rescue AccessRevoked
      false
    end

    def trusted_organization_id!(account, error_class)
      deterministic = deterministic_organization_id(account.id)
      stored = organization_id_for(account).presence
      raise error_class, "Postiz organization mapping が決定的IDと一致しません account_id=#{account.id}" if stored && stored != deterministic

      deterministic
    end

    def mapped_role!(account_user, error_class)
      role = ROLE_MAP[account_user.role.to_s]
      raise error_class, 'Chatwoot のroleをPostizへ安全に対応付けできません' unless role

      role
    end

    def lock_account!(account_id)
      exec('SELECT pg_advisory_xact_lock($1, $2)', [POSTIZ_ADVISORY_LOCK_NAMESPACE, Integer(account_id)])
    end

    def with_chatwoot_identity_locks(user_id: nil, account_ids: [])
      Account.transaction(requires_new: true) do
        chatwoot_advisory_lock!(CHATWOOT_USER_LOCK_NAMESPACE, user_id) if user_id
        account_ids.map { |id| Integer(id) }.uniq.sort.each do |account_id|
          chatwoot_advisory_lock!(CHATWOOT_ACCOUNT_LOCK_NAMESPACE, account_id)
        end
        yield
      end
    end

    def chatwoot_advisory_lock!(namespace, record_id)
      Account.connection.raw_connection.exec_params(
        'SELECT pg_advisory_xact_lock($1, $2)',
        [Integer(namespace), Integer(record_id)]
      )
    end

    def ensure_organization(account, organization_id)
      expected = deterministic_organization_id(account.id)
      raise IdentityConflict, 'Postiz organization id がChatwoot accountに束縛されていません' unless organization_id == expected

      row = query_one(
        <<~SQL.squish,
          INSERT INTO "Organization" (id, name, "createdAt", "updatedAt", "allowTrial", "isTrailing")
          VALUES ($1, $2, NOW(), NOW(), false, false)
          ON CONFLICT (id) DO UPDATE
            SET name = EXCLUDED.name, "updatedAt" = NOW(), "deletedAt" = NULL
          RETURNING id
        SQL
        [organization_id, account.name]
      )
      raise IdentityConflict, 'Postiz organization を確定できません' unless row&.fetch('id', nil) == organization_id
    end

    def remember_organization(account, organization_id)
      return if organization_id_for(account) == organization_id

      account.with_lock do
        account.reload
        attributes = (account.internal_attributes || {}).deep_dup
        postiz = (attributes['postiz'] || {}).dup
        existing = postiz['organization_id'].presence
        raise MappingConflict, "Postiz organization mapping が競合しました account_id=#{account.id}" if existing && existing != organization_id

        postiz['organization_id'] = organization_id
        # lifecycle callback の再帰を避け、この lock 内で mapping だけを確定する。
        account.update_columns( # rubocop:disable Rails/SkipsModelValidations
          internal_attributes: attributes.merge('postiz' => postiz), updated_at: Time.current
        )
      end
    end

    # identity collision の全分岐を一つの transaction で判定する。
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def ensure_user(user)
      provider_id = provider_id_for(user.id)
      expected_user_id = deterministic_user_id(user.id)
      provider_rows = users_by_provider(provider_id, lock: true)
      raise IdentityConflict, "Postiz user が重複しています provider_id=#{provider_id}" if provider_rows.length > 1

      email_row = query_one(
        <<~SQL.squish,
          SELECT id, "providerId"
            FROM "User"
           WHERE email = $1 AND "providerName" = 'GENERIC'::"Provider"
           FOR UPDATE
        SQL
        [user.email]
      )

      if provider_rows.one?
        postiz_user_id = provider_rows.first.fetch('id')
        raise IdentityConflict, 'Postiz providerId が別の user id に束縛されています' unless postiz_user_id == expected_user_id
        raise IdentityConflict, 'Postiz の email と providerId が別利用者を指しています' if email_row && email_row.fetch('id') != postiz_user_id
      elsif email_row
        raise IdentityConflict, '同期前に作られた別の GENERIC 利用者が同じ email を使用しています'
      else
        postiz_user_id = expected_user_id
        exec(
          <<~SQL.squish,
            INSERT INTO "User" (id, email, "providerName", "providerId", name, timezone,
                                activated, "createdAt", "updatedAt", "lastReadNotifications", "lastOnline")
            VALUES ($1, $2, 'GENERIC'::"Provider", $3, $4, 0, true, NOW(), NOW(), NOW(), NOW())
            ON CONFLICT DO NOTHING
          SQL
          [postiz_user_id, user.email, provider_id, user.name]
        )
        provider_rows = users_by_provider(provider_id, lock: true)
        raise IdentityConflict, 'Postiz user の決定的 upsert が競合しました' unless provider_rows.one? && provider_rows.first.fetch('id') == postiz_user_id
      end

      exec(
        <<~SQL.squish,
          UPDATE "User"
             SET email = $2, name = $3, activated = true, "deletedAt" = NULL, "updatedAt" = NOW()
           WHERE id = $1
        SQL
        [postiz_user_id, user.email, user.name]
      )
      postiz_user_id
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    def users_by_provider(provider_id, lock: false)
      query_all(
        <<~SQL.squish,
          SELECT id, email
            FROM "User"
           WHERE "providerId" = $1 AND "providerName" = 'GENERIC'::"Provider"
           #{'FOR UPDATE' if lock}
        SQL
        [provider_id]
      )
    end

    def ensure_membership(postiz_user_id, organization_id, role)
      exec(
        <<~SQL.squish,
          INSERT INTO "UserOrganization" (id, "userId", "organizationId", role, disabled, "createdAt", "updatedAt")
          VALUES ($1, $2, $3, $4::"Role", false, NOW(), NOW())
          ON CONFLICT ("userId", "organizationId") DO UPDATE
            SET role = EXCLUDED.role, disabled = false, "updatedAt" = NOW()
        SQL
        [SecureRandom.uuid, postiz_user_id, organization_id, role]
      )
    end

    def verify_access!(chatwoot_user_id, organization_id, expected_role)
      rows = query_all(
        <<~SQL.squish,
          SELECT u.id AS user_id, uo.role::text AS role
            FROM "User" u
            JOIN "UserOrganization" uo ON uo."userId" = u.id
            JOIN "Organization" o ON o.id = uo."organizationId"
           WHERE u."providerName" = 'GENERIC'::"Provider"
             AND u."providerId" = $1
             AND u.id = $3
             AND u.activated = true
             AND u."deletedAt" IS NULL
             AND uo."organizationId" = $2
             AND uo.disabled = false
             AND o."deletedAt" IS NULL
        SQL
        [provider_id_for(chatwoot_user_id), organization_id, deterministic_user_id(chatwoot_user_id)]
      )
      raise AccessRevoked, 'Postiz の有効な所属または role を確認できません' unless rows.one? && rows.first.fetch('role') == expected_role

      rows.first
    end

    def revoke_user_from_organization!(chatwoot_user_id, organization_id, disable_membership:)
      provider_id = provider_id_for(chatwoot_user_id)
      if disable_membership
        disable_membership_for_provider!(provider_id, organization_id)
      else
        demote_membership_for_provider!(provider_id, organization_id)
      end

      deactivate_user_without_memberships!(chatwoot_user_id) if disable_membership
    end

    def disable_memberships_for_provider!(provider_id)
      user_id = deterministic_user_id(provider_id.delete_prefix('cw:'))
      exec(
        <<~SQL.squish,
          UPDATE "UserOrganization" uo
             SET disabled = true, "updatedAt" = NOW()
            FROM "User" u
           WHERE u.id = uo."userId"
             AND u."providerName" = 'GENERIC'::"Provider"
             AND u."providerId" = $1
             AND u.id = $2
        SQL
        [provider_id, user_id]
      )
    end

    def deactivate_provider_user!(provider_id)
      user_id = deterministic_user_id(provider_id.delete_prefix('cw:'))
      exec(
        <<~SQL.squish,
          UPDATE "User"
             SET activated = false, "updatedAt" = NOW()
           WHERE "providerName" = 'GENERIC'::"Provider"
             AND "providerId" = $1
             AND id = $2
        SQL
        [provider_id, user_id]
      )
    end

    def disable_membership_for_provider!(provider_id, organization_id)
      user_id = deterministic_user_id(provider_id.delete_prefix('cw:'))
      exec(
        <<~SQL.squish,
          UPDATE "UserOrganization" uo
             SET disabled = true, "updatedAt" = NOW()
            FROM "User" u
           WHERE u.id = uo."userId"
             AND uo."organizationId" = $2
             AND u."providerName" = 'GENERIC'::"Provider"
             AND u."providerId" = $1
             AND u.id = $3
        SQL
        [provider_id, organization_id, user_id]
      )
    end

    def demote_membership_for_provider!(provider_id, organization_id)
      user_id = deterministic_user_id(provider_id.delete_prefix('cw:'))
      exec(
        <<~SQL.squish,
          UPDATE "UserOrganization" uo
             SET role = 'USER'::"Role", "updatedAt" = NOW()
            FROM "User" u
           WHERE u.id = uo."userId"
             AND uo."organizationId" = $2
             AND u."providerName" = 'GENERIC'::"Provider"
             AND u."providerId" = $1
             AND u.id = $3
        SQL
        [provider_id, organization_id, user_id]
      )
    end

    # Postiz Public API key は organization 共用なので、個人の所属削除・降格・削除では
    # 変更しない。account 全体を停止するときだけ、組織単位の資格情報として失効させる。
    # Public/OAuth/MCP 系は共通 API 境界でも遮断する。
    def revoke_organization_credentials!(organization_id)
      exec(
        'UPDATE "Organization" SET "apiKey" = NULL, "updatedAt" = NOW() WHERE id = $1',
        [organization_id]
      )
    end

    def deactivate_user_without_memberships!(chatwoot_user_id)
      postiz_user_id = deterministic_user_id(chatwoot_user_id)
      exec(
        <<~SQL.squish,
          UPDATE "User" u
             SET activated = false, "updatedAt" = NOW()
           WHERE u."providerName" = 'GENERIC'::"Provider"
             AND u."providerId" = $1
             AND u.id = $2
             AND NOT EXISTS (
               SELECT 1
                 FROM "UserOrganization" uo
                 JOIN "Organization" o ON o.id = uo."organizationId"
                WHERE uo."userId" = u.id
                  AND uo.disabled = false
                  AND o."deletedAt" IS NULL
             )
        SQL
        [provider_id_for(chatwoot_user_id), postiz_user_id]
      )
    end

    def deactivate_users_without_memberships!(organization_id)
      exec(
        <<~SQL.squish,
          UPDATE "User" u
             SET activated = false, "updatedAt" = NOW()
           WHERE u."providerName" = 'GENERIC'::"Provider"
             AND EXISTS (
               SELECT 1 FROM "UserOrganization" target
                WHERE target."userId" = u.id AND target."organizationId" = $1
             )
             AND NOT EXISTS (
               SELECT 1
                 FROM "UserOrganization" active_membership
                 JOIN "Organization" active_org ON active_org.id = active_membership."organizationId"
                WHERE active_membership."userId" = u.id
                  AND active_membership.disabled = false
                  AND active_org."deletedAt" IS NULL
             )
        SQL
        [organization_id]
      )
    end

    def provider_id_for(user_id)
      "cw:#{Integer(user_id)}"
    end

    def uuid_v5(namespace, name)
      namespace_bytes = [namespace.delete('-')].pack('H*')
      bytes = Digest::SHA1.digest(namespace_bytes + name.to_s).bytes.first(16)
      bytes[6] = (bytes[6] & 0x0f) | 0x50
      bytes[8] = (bytes[8] & 0x3f) | 0x80
      hex = bytes.pack('C*').unpack1('H*')
      "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
    end

    def with_transaction(&)
      connection.transaction(&)
    rescue PG::Error => e
      clear_connection!
      raise Unavailable, "Postiz DB との同期に失敗しました: #{e.class}"
    end

    def exec(sql, params = [])
      connection.exec_params(sql, params)
    end

    def query_one(sql, params = [])
      query_all(sql, params).first
    end

    def query_all(sql, params = [])
      exec(sql, params).to_a
    end

    def connection
      Thread.current[:toybaco_postiz_conn] ||= PG.connect(ENV.fetch('TOYBACO_POSTIZ_DATABASE_URL'))
    rescue PG::Error => e
      clear_connection!
      raise Unavailable, "Postiz DB へ接続できません: #{e.class}"
    end

    def clear_connection!
      current = Thread.current[:toybaco_postiz_conn]
      current&.close unless current&.finished?
    rescue PG::Error
      nil
    ensure
      Thread.current[:toybaco_postiz_conn] = nil
    end
  end
end
