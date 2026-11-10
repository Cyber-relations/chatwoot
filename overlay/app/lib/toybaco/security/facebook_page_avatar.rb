# frozen_string_literal: true

# CASA 5.1.1: registering a Facebook page puts params[:page_id], not encoded, into the Graph API image URL that the avatar
# job fetches (app/controllers/api/v1/accounts/callbacks_controller.rb:7, 17, 102-104). A page id is digits only: other
# values get the API's 422 before anything is saved, and the URL encodes the id.
module Toybaco::Security::FacebookPageAvatar
  PAGE_ID = /\A[0-9]{1,32}\z/

  def register_facebook_page
    page_id = params[:page_id]
    valid = (page_id.is_a?(String) || page_id.is_a?(Integer)) && page_id.to_s.match?(PAGE_ID)
    return render_could_not_create_error('Facebook ページの ID が正しくありません。') unless valid

    super
  end

  private

  def set_avatar(facebook_inbox, page_id)
    Avatar::AvatarFromUrlJob.perform_later(facebook_inbox, "https://graph.facebook.com/#{ERB::Util.url_encode(page_id.to_s)}/picture?type=large")
  end
end
