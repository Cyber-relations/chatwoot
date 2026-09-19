# frozen_string_literal: true

require_relative 'microsoft_send_context'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    class MicrosoftSendAttempt
      KEY = 'toybaco_microsoft_send'
      UNCERTAIN = '送信結果を確認しています。重複を防ぐため、再送せずお待ちください。'

      def initialize(message, channel)
        @message = message
        @channel = channel
      end

      def reserve
        @message.with_lock do
          saved = current
          return :uncertain if %w[preparing sending uncertain].include?(saved['state'])
          return if saved['state'] == 'accepted' || @message.source_id.present?
          return if @message.failed?

          attempt = { 'state' => 'preparing', 'attempt_id' => SecureRandom.hex(16), 'started_at' => Time.now.utc.iso8601,
                      'connection_revision' => Microsoft.config(@channel).fetch('connection_revision'),
                      'subject_id' => Microsoft.config(@channel).fetch('subject_id'),
                      'context_digest' => MicrosoftSendContext.new(@message).digest }
          write(attempt)
          attempt
        end
      end

      def prepared(attempt, draft)
        @message.with_lock do
          return unless same?(attempt) && current['state'] == 'preparing'

          write(current.merge('draft_id' => draft.fetch('id'), 'message_id' => draft['internetMessageId']))
        end
      end

      def claim_send(attempt)
        @channel.with_lock do
          return unless channel_current?(attempt)

          @message.with_lock do
            return unless same?(attempt) && current['state'] == 'preparing' && current['draft_id'].present?
            return unless context_current?(attempt)

            write(current.merge('state' => 'sending', 'send_started_at' => Time.now.utc.iso8601))
          end
        end
      end

      def accepted(attempt, draft: nil)
        @message.with_lock do
          return unless same?(attempt) && %w[sending uncertain accepted].include?(current['state'])

          saved = current.merge('state' => 'accepted', 'accepted_at' => Time.now.utc.iso8601)
          saved['provider_id'] = saved.fetch('draft_id')
          saved['message_id'] = internet_id(saved, draft)
          saved['sent_copy_at'] = Time.now.utc.iso8601 if draft
          @message.update!(source_id: saved.fetch('message_id'), status: :sent,
                           content_attributes: @message.content_attributes.except('external_error').merge(KEY => saved))
        end
      end

      def fail(attempt, uncertain: nil)
        @message.with_lock do
          return unless failure_allowed?(attempt)

          if attempt
            # Creating or attaching cannot send mail. A send attempt is the
            # irreversible boundary, and is never reset by later failures.
            uncertain = %w[sending uncertain].include?(current['state']) && uncertain != false
            write(current.merge('state' => uncertain ? 'uncertain' : 'rejected'))
          end
          text = uncertain ? UNCERTAIN : '送信できませんでした。接続を確認して、もう一度お試しください。'
          Messages::StatusUpdateService.new(@message, 'failed', text).perform
        end
      end

      def current
        value = @message.content_attributes[KEY]
        value.is_a?(Hash) ? value : {}
      end

      def connected_revision?(attempt)
        Microsoft.connected?(@channel) && @message.account_id == @channel.account_id &&
          Microsoft.config(@channel)['connection_revision'] == attempt['connection_revision']
      end

      def same_identity?(attempt)
        Microsoft.application_current?(@channel) && @message.account_id == @channel.account_id &&
          Microsoft.config(@channel)['subject_id'] == attempt['subject_id']
      end

      private

      def channel_current?(attempt)
        connected_revision?(attempt) && Microsoft.allowed?(@channel.account) && !@channel.reauthorization_required?
      end

      def context_current?(attempt)
        context = MicrosoftSendContext.new(@message)
        context.digest == attempt['context_digest'] && context.allowed?
      end

      def internet_id(saved, draft)
        id = draft&.fetch('internetMessageId', nil) || saved['message_id']
        header = Mail.new
        header.message_id = id.presence || "microsoft-#{Digest::SHA256.hexdigest(saved.fetch('draft_id'))}@toybaco.invalid"
        header.message_id
      end

      def failure_allowed?(attempt)
        current['state'] != 'accepted' && (!attempt || same?(attempt))
      end

      def same?(attempt)
        current['attempt_id'] == attempt['attempt_id']
      end

      def write(values)
        @message.update!(content_attributes: @message.content_attributes.merge(KEY => values))
        values
      end
    end
  end
end
