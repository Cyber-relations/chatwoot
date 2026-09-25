# frozen_string_literal: true

require_relative 'managed_auto'
require_relative '../legal_terms'

class Toybaco::Growth::ManagedAutoInstall
  AUTO = Toybaco::Growth::ManagedAuto

  def initialize(account_id, actor_id:)
    @account_id = account_id
    @actor_id = actor_id
  end

  def create!(inbox_id:, request_id:)
    request_id = AUTO.identifier!(request_id)
    AUTO.locked(@account_id) do |account|
      AUTO.administrator!(account, @actor_id)
      previous = AUTO::INSTALLATIONS.find_by(account_id: account.id)
      next previous if registration_replay?(previous, inbox_id, request_id)

      raise AUTO::Invalid unless AUTO.registration_available?(account) && !previous

      inbox = account.inboxes.lock('FOR UPDATE NOWAIT').find(inbox_id)
      AUTO::InboxRetention.check_access!(inbox, Time.now.utc)
      register!(account, inbox, request_id)
    end
  end

  def change!(mode:, generation:, epoch:, request_id:, consent: nil)
    validate_request!(mode, consent)
    request_id = AUTO.identifier!(request_id)
    expected = [mode.dup, generation.to_s.dup, AUTO.identifier!(epoch)]
    digest = Digest::SHA256.hexdigest(JSON.generate(expected))
    AUTO.locked(@account_id) do |account|
      AUTO.administrator!(account, @actor_id)
      installation = AUTO::INSTALLATIONS.find_by!(account_id: account.id)
      command = AUTO::COMMANDS.find_by(account_id: account.id, request_id: request_id)
      next replay!(command, installation, digest) if command

      validate_change!(account, installation, expected)

      switch!(account, installation, mode)
      AUTO::COMMANDS.create!(account_id: account.id, installation_id: installation.id, actor_id: @actor_id,
                             request_id: request_id, request_hash: digest)
      record_consent!(account) if mode == 'auto'
      installation
    end
  end

  private

  # 全自動の開始は、画面で説明と利用規約第7条の2への同意にチェックした要求だけ受け付ける。
  def validate_request!(mode, consent)
    raise AUTO::Invalid unless %w[auto stopped].include?(mode)
    raise AUTO::Invalid if mode == 'auto' && consent != true
  end

  def record_consent!(account)
    Toybaco::LegalTerms.record!(account, route: 'managed_auto', accepted_at: Time.now.utc, user_id: @actor_id)
  end

  def registration_replay?(previous, inbox_id, request_id)
    previous && previous.request_id == request_id && previous.inbox_id == inbox_id && previous.actor_id == @actor_id
  end

  def validate_change!(account, installation, expected)
    raise AUTO::Invalid unless expected.drop(1) == [installation.generation.to_s, installation.epoch]
    raise AUTO::Invalid if installation.generation == AUTO::MAX_GENERATION
    raise AUTO::Invalid if expected.first == 'auto' && !activatable?(account, installation)
  end

  def register!(account, inbox, request_id)
    bot = AgentBot.create!(account_id: account.id, name: '店舗AI', description: 'この店舗の確認済み情報から返信を作成します。')
    AgentBotInbox.create!(account_id: account.id, inbox: inbox, agent_bot: bot, status: :active)
    Toybaco::AiReplyMode.write_to!(account, 'draft')
    AUTO::INSTALLATIONS.create!(account_id: account.id, inbox_id: inbox.id, bot_id: bot.id, actor_id: @actor_id,
                                request_id: request_id, epoch: SecureRandom.uuid)
  end

  def replay!(command, installation, digest)
    raise AUTO::Invalid unless command.installation_id == installation.id && command.actor_id == @actor_id && command.request_hash == digest

    installation
  end

  def activatable?(account, installation)
    AUTO.enabled? && AUTO.eligible?(account) && AUTO.current_assignment?(installation) &&
      !AUTO.pending?(account.id) && installation.state != 'stopping' && inbox_available?(installation)
  end

  def inbox_available?(installation)
    AUTO::InboxRetention.check_access!(Inbox.find(installation.inbox_id), Time.now.utc)
    true
  end

  def switch!(account, installation, mode)
    floor = account.messages.where(inbox_id: installation.inbox_id).maximum(:id) || 0
    installation.update!(state: mode == 'auto' ? 'auto' : 'stopping', generation: installation.generation + 1,
                         epoch: SecureRandom.uuid, message_floor_id: floor, actor_id: @actor_id)
    Toybaco::AiReplyMode.write_to!(account, mode == 'auto' ? 'auto' : 'draft')
    AUTO.cancel_queue!(installation, 'installation_changed')
    AUTO::REQUESTS.unresolved.where(installation_id: installation.id).find_each { |request| AUTO.open_conversation!(request) }
    AUTO.finish_stop!(installation)
  end
end
