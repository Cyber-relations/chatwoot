# frozen_string_literal: true

# CASA 5.1.1: when no blob matches, upstream /slack_uploads redirects to a fallback image whose path is params[:sender_type],
# not encoded (app/controllers/slack_uploads_controller.rb:28-31). Accept only the names of the images in
# public/integrations/slack/ and the lowercase sender types upstream links to (send_on_slack_service.rb:92-99, 176-185).
module Toybaco::Security::SlackUploadAvatar
  SENDER_TYPES = %w[agent bot contact system user].freeze

  def show
    return head :not_found unless @blob || SENDER_TYPES.include?(params[:sender_type])

    super
  end

  private

  def avatar_url
    "#{ENV.fetch('FRONTEND_URL', nil)}/integrations/slack/#{ERB::Util.url_encode(params[:sender_type])}.png"
  end
end
