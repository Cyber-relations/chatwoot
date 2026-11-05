# frozen_string_literal: true

module Toybaco::Security::TelegramTokenRequired
  def process_payload
    return head :unauthorized if params[:bot_token].blank?

    super
  end
end
