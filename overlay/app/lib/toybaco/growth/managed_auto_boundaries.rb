# frozen_string_literal: true

require_relative 'managed_auto'

module Toybaco::Growth::ManagedAutoBoundaries
  AUTO = Toybaco::Growth::ManagedAuto

  module Hold
    private

    def install!
      AUTO.assert_holdable!(@account.id)
      super
    end
  end

  module Reservations
    private

    def duplicate(operation, kind, digest)
      if AUTO::REQUESTS.unresolved.exists?(account_id: @account.id, operation_id: operation.id)
        raise Toybaco::Growth::AiLedger::Conflict unless operation.kind == kind && operation.context_digest == digest

        return result_for(operation)
      end
      super
    end

    def reservation_counts(ids)
      # Unknown model results continue occupying their original reservation.
      # Wall-clock expiry is not evidence that an external invocation ended.
      unknown = AUTO::REQUESTS.unresolved.where(account_id: @account.id).select(:operation_id)
      operations.where(grant_id: ids, state: 'reserved').where('lease_expires_at > ? OR id IN (?)', @now, unknown).group(:grant_id).count
    end
  end

  # Existing normal contract/membership writers already call this under the
  # Account row fence, before external membership revocation. The same commit
  # revokes this managed installation, including change-and-restore histories.
  module Readiness
    def for_account(account)
      result = super
      row = AUTO::INSTALLATIONS.find_by(account_id: account.id)
      if row && AUTO.current_assignment?(row) && result['connection'] != 'unknown'
        result = result.merge('connection' => 'configured', 'configured_inboxes' => 1)
      end
      return result unless row || AUTO.registration_available?(account)

      result.merge('managed_auto_path' => "/toybaco/growth/automatic-replies?account_id=#{account.id}",
                   'managed_auto_registered' => row.present?)
    end
  end

  module LegacyMode
    def update
      return render json: { error: '窓口の自動応答設定で、開始・停止を選んでください。' }, status: :conflict if AUTO::INSTALLATIONS.exists?(account_id: @account.id)

      super
    end

    private

    def bot_covers_account?(bot, account)
      !AUTO.managed?(bot.id) && super
    end
  end

  module Principals
    def rotate!(account_id, user_ids: nil, now: Time.now.utc)
      AUTO.invalidate!(account_id, user_ids: user_ids)
      super
    end
  end

  module Mode
    def write_to!(account, mode)
      installation = AUTO::INSTALLATIONS.find_by(account_id: account.id)
      if installation
        raise AUTO::Invalid if mode == 'auto' && installation.state != 'auto'

        AUTO.invalidate!(account.id) if mode == 'draft' && installation.state == 'auto'
      end
      super
    end
  end

  module BotWrites
    extend ActiveSupport::Concern

    included do
      before_create :toybaco_managed_bot_create, prepend: true
      before_update :toybaco_managed_bot_change, prepend: true
      before_destroy :toybaco_managed_bot_destroy, prepend: true
    end

    private

    def toybaco_managed_bot_create
      return unless account_id
      return unless AUTO.enabled? || AUTO::INSTALLATIONS.exists?(account_id: account_id)

      AUTO.lock_writer!(account_id)
      raise AUTO::Invalid if AUTO::INSTALLATIONS.exists?(account_id: account_id)
    end

    def toybaco_managed_bot_change
      if toybaco_managed_bot_destination?
        AUTO.lock_writer!(account_id)
        raise AUTO::Invalid if AUTO::INSTALLATIONS.where(account_id: account_id).where.not(bot_id: id).exists?
      end
      toybaco_managed_bot_destroy if will_save_change_to_account_id? || will_save_change_to_outgoing_url?
    end

    def toybaco_managed_bot_destination?
      will_save_change_to_account_id? && account_id && (AUTO.enabled? || AUTO::INSTALLATIONS.exists?(account_id: account_id))
    end

    def toybaco_managed_bot_destroy
      installation = AUTO::INSTALLATIONS.find_by(bot_id: id)
      AUTO.invalidate!(installation.account_id) if installation
    end
  end

  module AssignmentWrites
    extend ActiveSupport::Concern

    included do
      before_create :toybaco_managed_assignment_create, prepend: true
      before_update :toybaco_managed_assignment_change, prepend: true
      before_destroy :toybaco_managed_assignment_destroy, prepend: true
    end

    private

    def toybaco_managed_assignment_create
      return unless AUTO.enabled? || AUTO::INSTALLATIONS.exists?(account_id: account_id)

      AUTO.lock_writer!(account_id)
      raise AUTO::Invalid if AUTO::INSTALLATIONS.exists?(account_id: account_id)
    end

    def toybaco_managed_assignment_change
      return unless changes_to_save.keys.intersect?(%w[agent_bot_id inbox_id account_id status])

      accounts = [account_id_in_database, account_id].compact.uniq.sort
      return unless AUTO.enabled? || AUTO::INSTALLATIONS.exists?(account_id: accounts)

      accounts.each { |account| AUTO.lock_writer!(account) }
      AUTO::INSTALLATIONS.where(account_id: accounts).each do |row|
        raise AUTO::Invalid unless toybaco_managed_assignment_matches?(row)
      end
      toybaco_managed_assignment_destroy
    end

    def toybaco_managed_assignment_matches?(row)
      row.bot_id == agent_bot_id_in_database && row.inbox_id == inbox_id_in_database
    end

    def toybaco_managed_assignment_destroy
      ids = [agent_bot_id_in_database, agent_bot_id].compact.uniq
      AUTO::INSTALLATIONS.where(bot_id: ids).order(:account_id).each { |row| AUTO.invalidate!(row.account_id) }
    end
  end

  module ApiToken
    def validate_bot_access_token!
      return render_unauthorized('Managed bot API access is unavailable') if @resource.is_a?(AgentBot) && AUTO.managed?(@resource.id)

      super
    end
  end

  module UsageApi
    private

    def bot_account(id)
      result = super
      result && !AUTO.managed?(@bot.id)
    end
  end

  module Delivery
    private

    def bot_active?
      return super unless @message.sender_type == 'AgentBot' && AUTO.managed?(@message.sender_id)

      installation = AUTO::INSTALLATIONS.find_by(bot_id: @message.sender_id, account_id: @account.id)
      request = AUTO::REQUESTS.find_by(operation_id: saved['operation_id'], account_id: @account.id)
      current_managed_result?(installation, request) && super
    end

    def current_managed_result?(installation, request)
      return false unless installation && request && AUTO.enabled?

      installation.state == 'auto' && request.state == 'completed' && AUTO.current_assignment?(installation) &&
        [request.generation, request.epoch] == [installation.generation, installation.epoch]
    end
  end
end
