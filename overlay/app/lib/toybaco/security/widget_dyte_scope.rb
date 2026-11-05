# frozen_string_literal: true

module Toybaco::Security::WidgetDyteScope
  private

  def set_message
    @message = Message.where(conversation_id: conversations.select(:id)).find(permitted_params[:message_id])
    @conversation = @message.conversation
  end
end
