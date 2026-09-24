# frozen_string_literal: true

require_relative 'managed_auto'

module Toybaco::Growth::ManagedAutoIngress
  AUTO = Toybaco::Growth::ManagedAuto

  module_function

  def receive(bot_id, payload)
    installation = AUTO::INSTALLATIONS.find_by(bot_id: bot_id)
    return unless installation && event_allowed?(payload)

    request = AUTO.locked(installation.account_id) do |account|
      installation.reload
      next unless AUTO.current_assignment?(installation)

      message = Message.find_by(id: payload[:id], account_id: account.id, inbox_id: installation.inbox_id)
      admit(account, installation, message) if incoming?(message)
    end
    enqueue(request) if request
  end

  def event_allowed?(payload)
    AUTO.enabled? && payload[:event].to_s == 'message_created' && payload[:id].is_a?(Integer) && payload[:id].positive?
  end

  # Persist the admission with the incoming Message. A process crash before
  # queue registration leaves an ID the sweeper can recover, never an event gap.
  def record(message)
    return unless public_incoming?(message)

    installation = AUTO::INSTALLATIONS.find_by(account_id: message.account_id, inbox_id: message.inbox_id)
    return unless installation

    account = AUTO.lock_writer!(message.account_id)
    installation.reload
    return unless AUTO.current_assignment?(installation)

    if AUTO.enabled? && incoming?(message)
      admit(account, installation, message)
    elsif message.conversation.pending?
      message.conversation.open!
    end
  end

  def after_commit(message)
    request = AUTO::REQUESTS.find_by(account_id: message.account_id, message_id: message.id)
    enqueue(request) if request
  end

  def admit(account, installation, message)
    if installation.state != 'auto' || Toybaco::AiReplyMode.read_from(account) != 'auto'
      message.conversation.open! if message.conversation.pending?
      return
    end
    return unless AUTO.eligible?(account) && message.conversation.pending? && message.id > installation.message_floor_id

    AUTO::InboxRetention.check_access!(message.inbox, Time.now.utc)
    persist_request(account, installation, message)
  end

  def persist_request(account, installation, message)
    AUTO::REQUESTS.find_or_create_by!(account_id: account.id, message_id: message.id) do |record|
      record.assign_attributes(inbox_id: message.inbox_id, conversation_id: message.conversation_id,
                               installation_id: installation.id, generation: installation.generation, epoch: installation.epoch,
                               enqueue_after: Time.now.utc)
    end
  end

  def public_incoming?(message)
    message.incoming? && !message.private?
  end

  def incoming?(message)
    message&.incoming? && !message.private? && message.content.is_a?(String) && message.content.present?
  end

  def enqueue(request)
    claimed = request.with_lock('FOR UPDATE NOWAIT') do
      next false unless request.state == 'queued' && request.enqueue_after <= Time.now.utc

      request.update!(enqueue_after: Time.now.utc + 60)
      true
    end
    Toybaco::ManagedAutoJob.perform_later(request.id) if claimed
  rescue StandardError => e
    Rails.logger.warn("toybaco_managed_auto_enqueue request=#{request.id} class=#{e.class}")
  end

  module MessageWrites
    extend ActiveSupport::Concern

    included do
      after_create :toybaco_managed_auto_admission, prepend: true
      after_create_commit :toybaco_managed_auto_enqueue
    end

    private

    def toybaco_managed_auto_admission
      Toybaco::Growth::ManagedAutoIngress.record(self)
    end

    def toybaco_managed_auto_enqueue
      Toybaco::Growth::ManagedAutoIngress.after_commit(self) if incoming? && !private?
    end
  end

  module Listener
    private

    def process_webhook_bot_event(agent_bot, payload)
      return super unless AUTO.managed?(agent_bot.id)

      Toybaco::Growth::ManagedAutoIngress.receive(agent_bot.id, payload)
    end
  end
end
