# frozen_string_literal: true

require_relative 'inbox_retention'
require_relative 'inbox_dispatch'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module InboxRetentionBoundaries
      module HttpErrors
        def self.included(base)
          base.rescue_from InboxRetention::Held, InboxRetention::Busy, InboxRetention::Invalid, InboxDispatch::Stale do |error|
            render json: { error: error.message }, status: :conflict
          end
        end
      end

      module SendJob
        def perform(message_id)
          InboxRetention.with_inbox(Message.find(message_id).inbox) { super }
        end
      end

      # Covers Base::SendOnChannelService and the direct Gmail/Microsoft paths,
      # including every attachment in the operation and the provider response.
      module SendService
        def perform
          return InboxRetention.with_inbox(@message.inbox) { super } unless @message.outgoing? || @message.template?

          InboxDispatch.deliver(@message) { super }
        end
      end

      module MailDelivery
        def self.included(base)
          base.around_deliver :toybaco_retention_mail_delivery
        end

        private

        def toybaco_retention_mail_delivery(&)
          return yield if action_name == 'conversation_transcript'
          return yield if message.is_a?(ActionMailer::Base::NullMail)

          InboxRetention.with_inbox(@conversation&.inbox) do
            toybaco_delivery_targets.each { |target| InboxDispatch.deliver(target) { true } }
            yield
          end
        end

        def toybaco_delivery_targets
          return [@message] if @message
          raise InboxRetention::Invalid unless @toybaco_dispatch_first_id

          targets = if @messages
                      @messages.select { |item| toybaco_current_delivery_target?(item) }
                    else
                      @conversation.messages.where(message_type: %i[outgoing template])
                                   .where('id >= ?', @toybaco_dispatch_first_id).limit(10_001).to_a
                    end
          raise InboxRetention::Invalid if targets.size > 10_000

          targets
        end

        def toybaco_current_delivery_target?(item)
          item.id >= @toybaco_dispatch_first_id && (item.outgoing? || item.template?)
        end
      end

      module MailTargets
        def reply_with_summary(conversation, last_queued_id)
          @toybaco_dispatch_first_id = last_queued_id
          super
        end

        def reply_without_summary(conversation, last_queued_id)
          @toybaco_dispatch_first_id = last_queued_id
          super
        end
      end

      module MessageCreation
        def self.included(base)
          base.around_create :toybaco_retention_message_creation
        end

        private

        def toybaco_retention_message_creation(&)
          self.additional_attributes = (additional_attributes || {}).except(InboxDispatch::RETRY_KEY)
          return yield if private? || activity?

          raise InboxRetention::Invalid unless inbox.account_id == account_id && conversation.inbox_id == inbox_id &&
                                               conversation.account_id == account_id

          InboxRetention.with_inbox(inbox, &)
        end
      end

      module Builder
        def perform
          return super if ActiveModel::Type::Boolean.new.cast(@private) || @message_type.to_s == 'activity'

          InboxRetention.with_inbox(@conversation.inbox) { super }
        end
      end

      module Retry
        def retry
          return super if message.blank?

          InboxRetention.with_inbox(message.inbox) { InboxDispatch.with_retry(message, Current.user) { super } }
        end

        private

        def claim_message_retry
          InboxDispatch.claim_retry(message, Current.user) { super }
        end
      end

      module FetchJob
        def perform(channel, interval = 1)
          InboxRetention.with_inbox(channel.inbox) { super }
        end
      end

      module OAuthFetchJob
        def perform(channel_id)
          channel = Channel::Email.find_by(id: channel_id)
          return unless channel

          InboxRetention.with_inbox(channel.inbox) { super }
        end
      end

      module ImapMailbox
        def process(mail, channel)
          InboxRetention.with_inbox(channel.inbox) { super }
        end
      end

      module OAuthIngest
        def call
          InboxRetention.with_inbox(@channel.inbox) { super }
        end
      end

      module InboxService
        def perform
          InboxRetention.with_inbox(@inbox) { super }
        end
      end

      module ChannelService
        def perform
          InboxRetention.with_inbox(channel.inbox) { super }
        end
      end

      # The finder can persist a contact before process starts. Enclose both
      # callbacks and ingestion in one transaction, retaining the finder's
      # shared xact lock until the complete mail operation commits or rolls back.
      # ActionMailbox tracks failed/delivered outside this callback transaction.
      module MailboxProcessing
        def self.included(base)
          base.around_processing :toybaco_retention_mailbox_transaction, prepend: true
        end

        private

        def toybaco_retention_mailbox_transaction(&)
          Account.transaction(requires_new: true, &)
        end
      end

      module NewMailConversation
        def find
          return super unless @channel

          InboxRetention.with_inbox(@inbox) { super }
        end
      end

      module ReplyMailbox
        def process
          return super unless @conversation

          InboxRetention.with_inbox(@conversation.inbox) { super }
        end
      end
    end
  end
end
