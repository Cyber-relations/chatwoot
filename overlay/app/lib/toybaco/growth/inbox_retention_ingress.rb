# frozen_string_literal: true

require_relative 'inbox_retention_boundaries'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module InboxRetentionIngress
      module Twilio
        def perform
          target = twilio_channel
          return super unless target

          InboxRetention.with_inbox(target.inbox) { super }
        end
      end

      module Whatsapp
        private

        # Delivery acknowledgements remain readable; new messages/echoes stop
        # before the Redis dedup marker, profile lookup or contact creation.
        def process_messages
          InboxRetention.with_inbox(@inbox) { super }
        end
      end

      module ConversationCreation
        def self.included(base)
          base.around_create :toybaco_retention_conversation_creation
        end

        private

        def toybaco_retention_conversation_creation(&)
          raise InboxRetention::Invalid unless inbox.account_id == account_id

          InboxRetention.with_inbox(inbox, &)
        end
      end

      module PublicCreate
        def create
          box = @inbox_channel.inbox
          raise InboxRetention::Invalid if @contact_inbox && @contact_inbox.inbox_id != box.id
          raise InboxRetention::Invalid if @conversation && @conversation.inbox_id != box.id

          InboxRetention.with_inbox(box) { super }
        end
      end

      module WidgetRequest
        private

        def toybaco_retention_widget_request(&)
          box = @web_widget.inbox
          raise InboxRetention::Invalid unless inbox.id == box.id && @contact_inbox.inbox_id == box.id

          InboxRetention.with_inbox(box, &)
        end
      end

      module WidgetMessages
        def self.included(base)
          base.include(WidgetRequest)
          # Keep authentication and the resolved-conversation check in their
          # existing order. Move only the create-side effect into the fence.
          base.skip_before_action :set_conversation, only: :create
          base.around_action :toybaco_retention_widget_request, only: :create
          base.before_action :set_conversation, only: :create
        end
      end

      module WidgetConversations
        def self.included(base)
          base.include(WidgetRequest)
          base.around_action :toybaco_retention_widget_request, only: :create
        end
      end
    end
  end
end
