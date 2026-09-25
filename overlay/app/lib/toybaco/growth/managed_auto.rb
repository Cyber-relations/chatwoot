# frozen_string_literal: true

require 'securerandom'
require_relative 'ai_ledger'
require_relative 'inbox_retention'
require_relative 'store_facts'
require_relative 'renewal_coordinator_fence'
require_relative '../ai_reply_mode'

module Toybaco::Growth::ManagedAuto
  InboxRetention = Toybaco::Growth::InboxRetention
  StoreFacts = Toybaco::Growth::StoreFacts
  INSTALLATIONS = Toybaco::GrowthAutoInstallation
  REQUESTS = Toybaco::GrowthAutoRequest
  COMMANDS = Toybaco::GrowthAutoCommand
  CAPABILITY = 'managed-auto-v1'
  MAX_GENERATION = 9_223_372_036_854_775_807
  class Invalid < StandardError; end

  module_function

  def enabled? = ENV['TOYBACO_MANAGED_AUTO_ENABLED'] == 'true'

  def managed?(bot_id) = INSTALLATIONS.exists?(bot_id: bot_id)

  def eligible?(account)
    return false if Toybaco::Growth::RenewalCoordinatorFence.pending(account.id)

    contract = Toybaco::Entitlements.contract_for(account)
    terms = Toybaco::Entitlements.for_account(account)
    return false unless supported_contract?(contract)

    account.active? && terms&.dig('ai_meter') == Toybaco::GrowthTerms::METER &&
      terms.dig('features', 'ai_auto_reply') == true && StoreFacts.new(account).read['confirmed']
  end

  def supported_contract?(contract)
    contract && contract['plan_version'] == Toybaco::GrowthTerms::VERSION && %w[standard pro].include?(contract['plan_id'])
  end

  def registration_available?(account)
    enabled? && eligible?(account) && !AgentBot.exists?(account_id: account.id) && !AgentBotInbox.exists?(account_id: account.id)
  end

  def locked(account_id)
    connection = Account.connection
    raise Invalid if connection.transaction_open?

    Account.uncached do
      Account.transaction do
        raise Invalid unless connection.select_value('SHOW transaction_isolation') == 'read committed'

        yield Account.lock('FOR UPDATE NOWAIT').find(account_id)
      end
    end
  rescue ActiveRecord::LockWaitTimeout
    raise InboxRetention::Busy
  end

  def administrator!(account, user_id)
    membership = account.account_users.find_by(user_id: user_id, role: :administrator)
    user = User.find_by(id: user_id)
    raise Invalid unless user&.confirmed? && membership && membership.custom_role_id.nil?
  end

  def identifier!(value)
    raise Invalid unless value.is_a?(String) && value.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)

    value.dup
  end

  def current_assignment?(installation)
    bot = AgentBot.find_by(id: installation.bot_id, account_id: installation.account_id, outgoing_url: nil)
    bot && Inbox.exists?(id: installation.inbox_id, account_id: installation.account_id) &&
      AgentBotInbox.exists?(inbox_id: installation.inbox_id, account_id: installation.account_id, agent_bot_id: bot.id, status: :active)
  end

  def pending?(account_id, inbox_id = nil)
    rows = REQUESTS.unresolved.where(account_id: account_id)
    rows = rows.where(inbox_id: inbox_id) if inbox_id
    rows.exists?
  end

  def assert_holdable!(account_id)
    raise InboxRetention::Busy if pending?(account_id)
  end

  def finish_stop!(installation)
    return unless installation.state == 'stopping' && !pending?(installation.account_id)

    installation.update!(state: 'stopped')
  end

  def lock_writer!(account_id)
    connection = Account.connection
    raise Invalid unless connection.transaction_open? && connection.select_value('SHOW transaction_isolation') == 'read committed'

    Account.uncached { Account.lock('FOR UPDATE NOWAIT').find(account_id) }
  rescue ActiveRecord::LockWaitTimeout
    raise InboxRetention::Busy
  end

  def invalidate!(account_id, user_ids: nil)
    return unless INSTALLATIONS.exists?(account_id: account_id)

    Account.uncached do
      lock_writer!(account_id)
      installation = INSTALLATIONS.find_by(account_id: account_id)
      next if user_ids&.exclude?(installation.actor_id)

      assert_holdable!(account_id)
      raise Invalid if installation.generation == MAX_GENERATION

      installation.update!(state: 'stopped', generation: installation.generation + 1, epoch: SecureRandom.uuid)
      cancel_queue!(installation, 'authority_changed')
    end
  rescue ActiveRecord::LockWaitTimeout
    raise InboxRetention::Busy
  end

  def open_conversation!(request)
    conversation = Conversation.find_by(id: request.conversation_id, account_id: request.account_id, inbox_id: request.inbox_id)
    conversation&.with_lock { conversation.open! if conversation.pending? }
  end

  def cancel_queue!(installation, reason)
    REQUESTS.where(installation_id: installation.id, state: 'queued').find_each do |request|
      request.update!(state: 'cancelled', terminal_at: Time.now.utc, reason: reason)
      open_conversation!(request)
    end
  end

  def public_state(installation)
    return { 'state' => 'unconnected' } unless installation

    { 'state' => installation.state, 'inbox_id' => installation.inbox_id, 'generation' => installation.generation.to_s,
      'epoch' => installation.epoch, 'pending' => pending?(installation.account_id), 'live_verification' => 'unverified' }
  end
end
