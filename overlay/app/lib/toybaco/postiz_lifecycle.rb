# frozen_string_literal: true

# Chatwoot の Account / AccountUser / User lifecycle を Postiz へ一方向同期する。
#
# - revoke / demotion / suspension は before_* で同期実行し、失敗時は Chatwoot 側も rollback
# - create / promotion / re-enable は commit 後に付与し、失敗時は durable job で再試行
#
# 二つの DB を原子的に commit できないため、常に「過剰付与より一時的な拒否」を選ぶ。
class Toybaco::PostizLifecycle
  class << self
    def reconcile_account_user!(user_id:, account_id:)
      account = Account.find_by(id: account_id)
      user = User.find_by(id: user_id)

      if account && user && eligible?(user, account)
        Toybaco::PostizSync.sync!(user: user, account: account)
      elsif account
        Toybaco::PostizSync.revoke_membership!(user_id: user_id, account: account)
      end
    end

    def reconcile_account_user(user_id:, account_id:)
      reconcile_account_user!(user_id: user_id, account_id: account_id)
    rescue StandardError => e
      Rails.logger.error(
        "[トイバコID] Postiz 所属同期を再試行します user_id=#{user_id} account_id=#{account_id}: #{e.class}"
      )
      Toybaco::PostizMembershipJob.perform_later(user_id, account_id)
    end

    def reconcile_account(account)
      account.account_users.pluck(:user_id).each do |user_id|
        reconcile_account_user(user_id: user_id, account_id: account.id)
      end
    end

    def eligible?(user, account)
      account.active? && Toybaco::PostizSync.enabled?(account) &&
        AccountUser.exists?(user_id: user.id, account_id: account.id)
    end

    def managed_accounts_for(user)
      user.accounts.select { |account| Toybaco::PostizSync.managed?(account) }
    end

    def account_will_become_ineligible?(account)
      old_status, new_status = before_change(account, 'status')
      old_attributes, new_attributes = before_change(account, 'internal_attributes')
      eligible_values?(old_status, old_attributes) && !eligible_values?(new_status, new_attributes)
    end

    def account_became_eligible?(account)
      old_status, new_status = after_change(account, 'status')
      old_attributes, new_attributes = after_change(account, 'internal_attributes')
      !eligible_values?(old_status, old_attributes) && eligible_values?(new_status, new_attributes)
    end

    private

    def before_change(record, attribute)
      record.changes_to_save.fetch(attribute) { [record.public_send(attribute), record.public_send(attribute)] }
    end

    def after_change(record, attribute)
      record.previous_changes.fetch(attribute) { [record.public_send(attribute), record.public_send(attribute)] }
    end

    def eligible_values?(status, internal_attributes)
      active_status?(status) && postiz_enabled_value?(internal_attributes)
    end

    def active_status?(status)
      value = status.is_a?(Integer) ? Account.statuses.key(status) : status.to_s
      value == 'active'
    end

    def postiz_enabled_value?(attributes)
      attributes&.dig('postiz', 'enabled') == true
    end
  end

  module AccountUserHooks
    extend ActiveSupport::Concern

    included do
      before_update :toybaco_postiz_demote_before_commit, if: :toybaco_postiz_role_demotion?
      before_destroy :toybaco_postiz_revoke_before_destroy
      after_create_commit :toybaco_postiz_reconcile_after_commit
      after_update_commit :toybaco_postiz_reconcile_role_after_commit, if: :saved_change_to_role?
      after_rollback :toybaco_postiz_reconcile_after_rollback
    end

    private

    def toybaco_postiz_role_demotion?
      change = changes_to_save['role']
      return false unless change

      old_role = change.first.is_a?(Integer) ? self.class.roles.key(change.first) : change.first.to_s
      old_role == 'administrator' && role.to_s == 'agent'
    end

    def toybaco_postiz_demote_before_commit
      result = Toybaco::PostizSync.demote_membership!(user_id: user_id, account: account)
      @toybaco_postiz_pre_revoked = result == :demoted
    end

    def toybaco_postiz_revoke_before_destroy
      result = Toybaco::PostizSync.revoke_membership!(user_id: user_id, account: account)
      @toybaco_postiz_pre_revoked = result == :revoked
    end

    def toybaco_postiz_reconcile_after_commit
      Toybaco::PostizLifecycle.reconcile_account_user(user_id: user_id, account_id: account_id)
    end

    def toybaco_postiz_reconcile_role_after_commit
      toybaco_postiz_reconcile_after_commit
    end

    def toybaco_postiz_reconcile_after_rollback
      return unless @toybaco_postiz_pre_revoked

      Toybaco::PostizMembershipJob.perform_later(user_id, account_id)
      @toybaco_postiz_pre_revoked = false
    end
  end

  module AccountHooks
    extend ActiveSupport::Concern

    included do
      before_update :toybaco_postiz_disable_before_commit, if: :toybaco_postiz_will_become_ineligible?
      before_destroy :toybaco_postiz_disable_before_destroy
      after_update_commit :toybaco_postiz_reconcile_account_after_commit
      after_rollback :toybaco_postiz_reconcile_account_after_rollback
    end

    private

    def toybaco_postiz_will_become_ineligible?
      Toybaco::PostizLifecycle.account_will_become_ineligible?(self)
    end

    def toybaco_postiz_disable_before_commit
      result = Toybaco::PostizSync.disable_account!(account: self, force: true)
      @toybaco_postiz_pre_revoked = result == :disabled
    end

    def toybaco_postiz_disable_before_destroy
      result = Toybaco::PostizSync.disable_account!(account: self)
      @toybaco_postiz_pre_revoked = result == :disabled
    end

    def toybaco_postiz_reconcile_account_after_commit
      return unless Toybaco::PostizLifecycle.account_became_eligible?(self) ||
                    (active? && Toybaco::PostizSync.enabled?(self) && previous_changes.key?('name'))

      Toybaco::PostizLifecycle.reconcile_account(self)
    end

    def toybaco_postiz_reconcile_account_after_rollback
      return unless @toybaco_postiz_pre_revoked

      Toybaco::PostizLifecycle.reconcile_account(self) if persisted?
      @toybaco_postiz_pre_revoked = false
    end
  end

  module UserHooks
    extend ActiveSupport::Concern

    included do
      before_destroy :toybaco_postiz_disable_user_before_destroy
      after_update_commit :toybaco_postiz_reconcile_identity_after_commit, if: :toybaco_postiz_identity_changed?
      after_rollback :toybaco_postiz_reconcile_user_after_rollback
    end

    private

    def toybaco_postiz_disable_user_before_destroy
      return if Toybaco::PostizLifecycle.managed_accounts_for(self).empty?

      Toybaco::PostizSync.disable_user!(user_id: id)
      @toybaco_postiz_pre_revoked = true
    end

    def toybaco_postiz_identity_changed?
      saved_change_to_email? || saved_change_to_name?
    end

    def toybaco_postiz_reconcile_identity_after_commit
      Toybaco::PostizLifecycle.managed_accounts_for(self).each do |account|
        Toybaco::PostizLifecycle.reconcile_account_user(user_id: id, account_id: account.id)
      end
    end

    def toybaco_postiz_reconcile_user_after_rollback
      return unless @toybaco_postiz_pre_revoked

      Toybaco::PostizLifecycle.managed_accounts_for(self).each do |account|
        Toybaco::PostizMembershipJob.perform_later(id, account.id)
      end
      @toybaco_postiz_pre_revoked = false
    end
  end
end
