# frozen_string_literal: true

module Toybaco::Security::TelegramEventToken
  def perform(params = {})
    return if params[:bot_token].blank?

    super
  end
end
