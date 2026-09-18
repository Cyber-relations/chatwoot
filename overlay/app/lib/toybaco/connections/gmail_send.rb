# frozen_string_literal: true

require_relative 'gmail'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    class GmailSend
      KEY = 'toybaco_gmail_send'
      UNCERTAIN = '送信結果を確認しています。重複を防ぐため、再送せずお待ちください。'

      def initialize(message)
        @message = message
        @channel = message.conversation.inbox.channel
      end

      def perform
        @reservation = nil
        return unless relevant_message?
        return fail_with('メールの接続を確認してください。') unless authorized?

        token = Gmail.access_token(@channel)
        mail = ConversationReplyMailer.with(account: @message.account).email_reply(@message).message
        @reservation = reserve
        return resolve if @reservation == :uncertain
        return unless @reservation.is_a?(Hash)

        deliver(mail, token)
      rescue GmailApi::Error => e
        @channel.prompt_reauthorization! if e.authorization_failure?
        handle_failure(uncertain: e.possibly_accepted?)
      rescue IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError
        handle_failure(uncertain: true)
      rescue ArgumentError
        handle_failure(uncertain: false)
      end

      def resolve
        return unless Gmail.connected?(@channel) && Gmail.allowed?(@channel.account)

        saved = @message.reload.content_attributes[KEY]
        return unless saved.is_a?(Hash) && %w[sending uncertain].include?(saved['state'])

        result = Gmail.api.sent_message(access_token: Gmail.access_token(@channel), message_id: saved.fetch('message_id'))
        found = result.fetch('messages', [])
        accepted(saved, found.first.fetch('id')) if found.length == 1
      end

      private

      def relevant_message?
        @message.email_notifiable_message? && Gmail.connected?(@channel)
      end

      def authorized?
        Gmail.allowed?(@channel.account) && !@channel.reauthorization_required?
      end

      def deliver(mail, token)
        mail.message_id = @reservation.fetch('message_id')
        result = Gmail.api.send_message(access_token: token, raw: mail.encoded)
        raise GmailApi::Error, 502 if result['id'].to_s.empty?

        accepted(@reservation, result.fetch('id'))
      end

      def handle_failure(uncertain:)
        return fail_with('メールの接続を確認して、もう一度お試しください。') unless @reservation.is_a?(Hash)

        uncertain ? uncertain(@reservation) : rejected(@reservation)
      end

      def reserve
        @message.with_lock do
          saved = @message.content_attributes[KEY] || {}
          return :uncertain if %w[sending uncertain].include?(saved['state'])
          return if saved['state'] == 'accepted'
          return if @message.source_id.present?

          attempt = { 'state' => 'sending', 'attempt_id' => SecureRandom.hex(16),
                      'message_id' => saved['message_id'] || "#{SecureRandom.uuid}@toybaco.jp", 'started_at' => Time.now.utc.iso8601 }
          @message.update!(content_attributes: @message.content_attributes.merge(KEY => attempt))
          attempt
        end
      end

      def accepted(attempt, provider_id)
        @message.with_lock do
          return unless same_attempt?(attempt)

          saved = attempt.merge('state' => 'accepted', 'provider_id' => provider_id, 'accepted_at' => Time.now.utc.iso8601)
          @message.update!(source_id: saved.fetch('message_id'), status: :sent,
                           content_attributes: @message.content_attributes.except('external_error').merge(KEY => saved))
        end
      end

      def uncertain(attempt)
        return unless update_attempt(attempt, 'uncertain', UNCERTAIN)

        Toybaco::GmailResolveSendJob.set(wait: 30.seconds).perform_later(@message.id)
      end

      def rejected(attempt)
        update_attempt(attempt, 'rejected', '送信できませんでした。接続を確認して、もう一度お試しください。')
      end

      def update_attempt(attempt, state, error)
        @message.with_lock do
          return unless same_attempt?(attempt)
          return if @message.content_attributes.dig(KEY, 'state') == 'accepted'

          @message.update!(content_attributes: @message.content_attributes.merge(KEY => attempt.merge('state' => state)))
          fail_with(error)
          true
        end
      end

      def same_attempt?(attempt)
        @message.content_attributes.dig(KEY, 'attempt_id') == attempt['attempt_id']
      end

      def fail_with(text)
        @message.with_lock do
          return if @message.content_attributes.dig(KEY, 'state') == 'accepted'

          Messages::StatusUpdateService.new(@message, 'failed', text).perform
        end
      end
    end

    module GmailSendRouting
      private

      def perform_reply
        return super unless Gmail.connected?(channel)

        GmailSend.new(message).perform
      end
    end

    module GmailMailer
      def email_reply(message)
        return super unless Gmail.connected?(message.conversation.inbox.channel)

        init_conversation_attributes(message.conversation)
        @message = message
        prepare_mail(true)
      end

      private

      def email_reply_to
        Gmail.connected?(@channel) ? @channel.email : super
      end
    end
  end
end
