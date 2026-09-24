# frozen_string_literal: true

require_relative 'managed_auto'
require_relative 'managed_auto_model'
require_relative 'bot_reply'
require_relative 'reply_result'

class Toybaco::Growth::ManagedAutoWork
  AUTO = Toybaco::Growth::ManagedAuto
  HANDOFF = "担当者への引き継ぎ\n\nAIで確かな回答を作成できなかったため、担当者が確認してください。"

  def initialize(request, model: Toybaco::Growth::ManagedAutoModel.new)
    @request = request
    @model = model
  end

  def perform
    inbox = Inbox.find_by(id: @request.inbox_id, account_id: @request.account_id)
    return cancel_queued! unless inbox

    AUTO::InboxRetention.with_inbox(inbox) do
      input = claim!
      next unless input

      result = @model.generate(input.fetch(:prompt))
      finish!(input, result)
    end
  rescue AUTO::InboxRetention::Busy
    # The durable queued request remains recoverable after transient contention.
    settle_failure! unless @request.reload.state == 'queued'
  rescue AUTO::InboxRetention::Held, AUTO::InboxRetention::Invalid, AUTO::Invalid
    settle_failure!
  rescue StandardError => e
    Rails.logger.warn("toybaco_managed_auto_failed request=#{@request.id} class=#{e.class}")
    settle_failure!
  end

  private

  def claim!
    AUTO.locked(@request.account_id) do |account|
      @request.reload
      next unless @request.state == 'queued'

      installation = AUTO::INSTALLATIONS.find_by(id: @request.installation_id, account_id: account.id)
      message = source_message(account)
      next cancel! unless current?(account, installation, message) && @request.created_at > Time.now.utc - 300

      conversation = message.conversation
      conversation.lock!
      next cancel_superseded! unless current_message?(conversation, message)
      next handoff_before_start!(conversation) if handoff_required?(conversation, message)

      start!(account, installation, conversation, message)
    end
  end

  def source_message(account)
    account.messages.find_by(id: @request.message_id, inbox_id: @request.inbox_id, conversation_id: @request.conversation_id)
  end

  def current?(account, installation, message)
    AUTO.enabled? && AUTO.eligible?(account) && valid_installation?(account, installation) &&
      Toybaco::AiReplyMode.read_from(account) == 'auto' && message&.incoming? && !message.private?
  end

  def valid_installation?(account, installation)
    return false unless installation

    AUTO.administrator!(account, installation.actor_id)
    installation.state == 'auto' && AUTO.current_assignment?(installation) &&
      [installation.generation, installation.epoch] == [@request.generation, @request.epoch]
  rescue AUTO::Invalid
    false
  end

  def start!(account, installation, conversation, message)
    input = reserve!(account, installation, conversation, message)
    return cancel! unless input

    @request.update!(state: 'started', operation_id: input.fetch(:operation_id), started_at: Time.now.utc)
    input
  end

  def current_message?(conversation, message)
    conversation.pending? && latest?(conversation, message)
  end

  def latest?(conversation, message)
    conversation.messages.where(message_type: :incoming, private: false).reorder(created_at: :desc, id: :desc).first&.id == message.id
  end

  def handoff_required?(conversation, message)
    reply_limit?(conversation) || unsupported_attachments?(message)
  end

  def unsupported_attachments?(message)
    message.attachments.exists?
  end

  def reply_limit?(conversation)
    conversation.messages.where(sender_type: 'AgentBot', private: false, message_type: :outgoing).count >= 3
  end

  def reserve!(account, installation, conversation, message)
    bot = AgentBot.find(installation.bot_id)
    service = Toybaco::Growth::BotReply.new(account, bot: bot, conversation: conversation, message: message)
    reservation = service.update(action_type: 'reserve')
    return unless reservation['result'] == 'reserved'

    { operation_id: reservation.fetch('operation_id'), token: reservation.fetch('token'),
      facts: reservation.fetch('facts'), prompt: Toybaco::Growth::ManagedAutoModel.prompt(reservation.fetch('facts'), history(conversation)) }
  end

  def history(conversation)
    remaining = 8000
    conversation.messages.where(private: false, message_type: %i[incoming outgoing]).reorder(id: :desc).limit(12).filter_map do |message|
      next if remaining.zero?

      text = message.content.to_s.first([remaining, 4000].min)
      remaining -= text.length
      { 'role' => message.incoming? ? 'customer' : 'store', 'content' => text }
    end.reverse
  end

  def finish!(input, result)
    AUTO.locked(@request.account_id) do |account|
      @request.reload
      next unless @request.state == 'started'

      installation = AUTO::INSTALLATIONS.find_by(id: @request.installation_id, account_id: account.id)
      message = source_message(account)
      if current?(account, installation, message)
        message.conversation.with_lock { persist!(account, installation, message, input, result) }
      else
        cancel_result!(account, message, input)
      end
      AUTO.finish_stop!(installation) if installation
    end
  end

  def cancel_result!(account, message, input)
    release!(account, input)
    message.conversation.open! if message&.conversation&.pending?
    @request.update!(state: 'cancelled', terminal_at: Time.now.utc, reason: 'access_changed')
  end

  def persist!(account, installation, message, input, result)
    conversation = message.conversation
    return release_superseded!(account, input) unless current_message?(conversation, message)

    bot = AgentBot.find(installation.bot_id)
    if result['action'] == 'handoff'
      persist_handoff!(account, conversation, bot, input)
      return
    end
    raise AUTO::Invalid unless result['action'] == 'answer' && Toybaco::Growth::DraftPrompt.urls_allowed?(result.fetch('reply'), input.fetch(:facts))

    service = Toybaco::Growth::BotReply.new(account, bot: bot, conversation: conversation, message: message)
    outcome = service.update(action_type: 'consumed', operation_id: input.fetch(:operation_id), token: input.fetch(:token),
                             reply: result.fetch('reply'), mode: 'auto')
    state = outcome['result'] == 'consumed' ? 'completed' : 'cancelled'
    @request.update!(state: state, terminal_at: Time.now.utc, reason: state == 'cancelled' ? 'generation_changed' : nil)
  end

  def persist_handoff!(account, conversation, bot, input)
    release!(account, input)
    handoff!(conversation, bot)
    @request.update!(state: 'handoff', terminal_at: Time.now.utc)
  end

  def release!(account, input)
    Toybaco::Growth::AiLedger.new(account).settle(operation_id: input.fetch(:operation_id), token: input.fetch(:token), outcome: 'released')
  end

  def handoff!(conversation, bot)
    conversation.messages.create!(account_id: conversation.account_id, inbox_id: conversation.inbox_id, sender: bot,
                                  message_type: :outgoing, private: true, content: HANDOFF)
    conversation.open!
  end

  def handoff_before_start!(conversation)
    handoff!(conversation, AgentBot.find(AUTO::INSTALLATIONS.find(@request.installation_id).bot_id))
    cancel!
  end

  def release_superseded!(account, input)
    release!(account, input)
    cancel_superseded!
  end

  def cancel_superseded!
    @request.update!(state: 'cancelled', terminal_at: Time.now.utc, reason: 'generation_changed')
    nil
  end

  def cancel!
    @request.update!(state: 'cancelled', terminal_at: Time.now.utc, reason: 'generation_unavailable')
    AUTO.open_conversation!(@request)
    nil
  end

  def cancel_queued!
    @request.with_lock { cancel! if @request.state == 'queued' }
  end

  def settle_failure!
    AUTO.locked(@request.account_id) do
      @request.reload
      cancel! if @request.state == 'queued'
      if @request.state == 'started'
        @request.update!(state: 'uncertain', reason: 'result_unknown')
        AUTO.open_conversation!(@request)
      end
    end
  end
end
