# frozen_string_literal: true

require_relative 'microsoft'
require_relative 'microsoft_send_attempt'
require_relative 'microsoft_outgoing'
require_relative 'microsoft_ingest'
require 'digest'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    class MicrosoftSend
      KEY = MicrosoftSendAttempt::KEY

      def initialize(message)
        @message = message
        @channel = message.conversation.inbox.channel
        @state = MicrosoftSendAttempt.new(message, @channel)
      end

      def perform
        return unless relevant_message?
        return @state.fail(nil) unless authorized?

        @token = Microsoft.access_token(@channel)
        @attempt = @state.reserve
        return resolve if @attempt == :uncertain
        return unless @attempt.is_a?(Hash)

        schedule_resolution
        mail = ConversationReplyMailer.with(account: @message.account).email_reply(@message).message
        @outgoing = MicrosoftOutgoing.new(mail, api: Microsoft.api, access_token: @token)
        deliver
      rescue MicrosoftApi::Error => e
        @channel.prompt_reauthorization! if e.authorization_failure?
        failure(uncertain: e.possibly_accepted?)
      rescue IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, ArgumentError, KeyError
        failure
      end

      def resolve
        saved = resolution
        return unless saved
        return stale_preparation(saved) if saved['state'] == 'preparing'
        return unless resolving_send?(saved)

        draft = Microsoft.api.message(access_token: Microsoft.access_token(@channel), id: saved.fetch('draft_id'))
        @state.accepted(saved, draft: draft) if sent_copy?(saved, draft)
      rescue MicrosoftApi::Error => e
        raise unless e.status == 404 # The sent copy can take time to appear.
      end

      private

      def relevant_message?
        @message.email_notifiable_message? && Microsoft.connected?(@channel)
      end

      def resolution
        return unless Microsoft.connected?(@channel) && authorized?

        saved = @message.reload.content_attributes[KEY]
        saved if saved.is_a?(Hash) && @state.same_identity?(saved)
      end

      def resolving_send?(saved)
        %w[sending uncertain accepted].include?(saved['state']) && saved['draft_id'].present?
      end

      def authorized?
        Microsoft.allowed?(@channel.account) && !@channel.reauthorization_required?
      end

      def deliver
        draft = create_draft
        raise MicrosoftApi::Error, 409 unless @state.prepared(@attempt, draft)

        @outgoing.attach(draft.fetch('id'))
        raise MicrosoftApi::Error, 409 unless @state.claim_send(@attempt)

        Microsoft.api.send_draft(access_token: @token, draft_id: draft.fetch('id'))
        @state.accepted(@attempt)
        schedule_resolution
      end

      def create_draft
        incoming = @message.conversation.messages.where(message_type: :incoming, private: false).order(id: :desc).first
        provider_id = incoming&.content_attributes&.dig(MicrosoftIngest::KEY, 'provider_id')
        if provider_id.present?
          Microsoft.api.create_reply(access_token: @token, message_id: provider_id, message: @outgoing.message)
        else
          Microsoft.api.create_draft(access_token: @token, message: @outgoing.message)
        end
      end

      def sent_copy?(saved, data)
        data['id'] == saved['draft_id'] && data['isDraft'] == false && Time.iso8601(data.fetch('sentDateTime')) <= Time.now.utc
      rescue KeyError, ArgumentError
        false
      end

      def stale_preparation(saved)
        # No send was claimed, so an abandoned preparation can be retried by
        # the user. It never authorizes an automatic send of an Outlook draft.
        @state.fail(saved) if Time.iso8601(saved.fetch('started_at')) < 5.minutes.ago
      end

      def failure(uncertain: nil)
        attempt = @attempt.is_a?(Hash) ? @attempt : nil
        @state.fail(attempt, uncertain: uncertain)
        schedule_resolution if attempt
      end

      def schedule_resolution
        Toybaco::MicrosoftResolveSendJob.set(wait: 30.seconds).perform_later(@message.id)
      end
    end

    module MicrosoftSendRouting
      private

      def perform_reply
        return super unless Microsoft.connected?(channel)

        MicrosoftSend.new(message).perform
      end
    end

    module MicrosoftMailer
      def email_reply(message)
        return super unless Microsoft.connected?(message.conversation.inbox.channel)

        init_conversation_attributes(message.conversation)
        @message = message
        prepare_mail(true)
      end

      private

      def email_reply_to
        Microsoft.connected?(@channel) ? @channel.email : super
      end
    end
  end
end
