# frozen_string_literal: true

require_relative '../billing_access'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module TrialNotice
      module_function

      def owner(account)
        user = User.find_by(id: owner_id(account), confirmed_at: ..Time.now.utc)
        user if user && BillingAccess.can_view?(account, user)
      end

      def owner_id(account)
        attrs = Entitlements.attributes(account)
        if attrs.key?(StoreFulfillment::PURCHASE)
          parent = BillingAccess.purchase_parent(account, attrs[StoreFulfillment::PURCHASE])
          attrs = parent ? Entitlements.attributes(parent) : {}
        end
        BillingAccess.valid_owner_id(attrs[BillingAccess::OWNER_KEY])
      end

      def issue!(account, trial, grant, now: Time.now.utc)
        return unless eligible?(account, trial, grant, now)

        kinds = due_kinds(trial, grant, now)
        return if kinds.empty?

        user = owner(account)
        return unless user

        kinds.each do |kind|
          Toybaco::GrowthTrialNotice.find_or_create_by!(account: account, trial: trial, kind: kind) do |notice|
            notice.user = user
          end
        end
      end

      def due_kinds(trial, grant, now)
        [].tap do |kinds|
          kinds << 'deadline' if trial.ends_at <= now + 3.days
          kinds << 'remaining' if grant.units - grant.used <= 20
        end
      end

      def active_trial?(trial, grant, now)
        !trial.completed_at && grant && !grant.revoked_at && trial.ends_at > now && grant.used < grant.units
      end

      def eligible?(account, trial, grant, now)
        account.active? && active_trial?(trial, grant, now) && trial.account_id == account.id && grant.account_id == account.id
      end

      def notices(account)
        trial = Toybaco::GrowthTrial.find_by(account_id: account.id, completed_at: nil)
        return [] unless trial

        Toybaco::GrowthTrialNotice.where(account_id: account.id, trial_id: trial.id).where.not(state: 'cancelled').order(:id).pluck(:kind)
      end
    end
  end
end
