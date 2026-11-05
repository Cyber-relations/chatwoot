# frozen_string_literal: true

module Toybaco::Security::WhatsappEventRoute
  def perform(params = {}, route: nil)
    @webhook_route = route&.with_indifferent_access
    super(params)
  end

  private

  def find_channel_by_url_param(params)
    # Preserve the argument contract for jobs already queued before this change.
    return super if @webhook_route.nil?
    return if @webhook_route[:phone_number].blank?

    Channel::Whatsapp.find_by(phone_number: @webhook_route[:phone_number])
  end
end
