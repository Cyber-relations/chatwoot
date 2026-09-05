# frozen_string_literal: true

require_relative 'entitlements'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # ライト(旧 starter)の担当者は LP どおり 3 名まで。
  # 判定は既存の internal_attributes['toybaco_plan'] だけを見る。課金は触らない。
  module AgentSeatLimit
    MESSAGE = 'このご契約の利用人数上限に達しています。ご契約内容をご確認ください。'

    module_function

    def plan_key(account)
      attrs = account.respond_to?(:internal_attributes) ? account.internal_attributes : nil
      attrs = {} unless attrs.is_a?(Hash)
      raw = attrs['toybaco_plan']
      raw = attrs[:toybaco_plan] if raw.nil?
      raw.to_s
    end

    def capped?(account)
      !limit_for(account).nil?
    end

    def limit_for(account)
      values = Toybaco::Entitlements.for_account(account)
      values&.fetch('limits')&.fetch('agents')
    rescue Toybaco::PlanCatalog::Invalid
      0 # An unknown explicit contract must not grant unlimited new seats.
    end

    def current_count(account)
      users = account.respond_to?(:account_users) ? account.account_users : nil
      return 0 unless users

      users.respond_to?(:count) ? users.count : 0
    end

    def at_limit?(account)
      cap = limit_for(account)
      return false unless cap

      current_count(account) >= cap
    end

    def payload(account)
      cap = limit_for(account)
      count = current_count(account)
      {
        'capped' => !cap.nil?,
        'limit' => cap,
        'count' => count,
        'at_limit' => !cap.nil? && count >= cap,
        'title' => cap.nil? ? '利用人数の上限なし' : "利用は#{cap}名まで",
        'message' => if cap.nil?
                       'このご契約に利用人数の上限はありません。'
                     else
                       "ご契約の利用人数は#{cap}名までです。現在#{count}名が利用しています。"
                     end
      }
    end

    def install!
      install_limit_copy!
      install_usage_limits!
      install_membership_guard!
    end

    def install_limit_copy!
      return unless defined?(::AgentBuilder::LimitExceededError)

      error = ::AgentBuilder::LimitExceededError
      return if error < LimitExceededCopy

      error.prepend(LimitExceededCopy)
    end

    def install_usage_limits!
      return unless defined?(::Account)
      return if ::Account < AccountUsageLimits

      ::Account.prepend(AccountUsageLimits)
    end

    def install_membership_guard!
      return unless defined?(::AccountUser)
      return if ::AccountUser < MembershipGuard

      ::AccountUser.prepend(MembershipGuard)
    end

    # AgentBuilder の 402 文言を LP の字面にする。
    module LimitExceededCopy
      def initialize(*_args)
        StandardError.instance_method(:initialize).bind_call(self, Toybaco::AgentSeatLimit::MESSAGE)
      end
    end

    # CE の usage_limits[:agents] は無制限固定。ライトだけ 3 にする。
    module AccountUsageLimits
      def usage_limits
        limits = super
        cap = Toybaco::AgentSeatLimit.limit_for(self)
        return limits unless cap && limits.is_a?(Hash)

        limits.merge(agents: cap)
      end
    end

    # AgentBuilder 以外の AccountUser 作成も同じ上限で止める。
    module MembershipGuard
      def self.prepended(base)
        base.validate :toybaco_reject_light_seat_overflow, on: :create
      end

      def toybaco_reject_light_seat_overflow
        acc = account
        return if acc.nil?
        return unless Toybaco::AgentSeatLimit.at_limit?(acc)

        errors.add(:base, Toybaco::AgentSeatLimit::MESSAGE)
      end
    end
  end
end
