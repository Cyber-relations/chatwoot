# frozen_string_literal: true

module Toybaco::Security::PortalLogoUploads
  def create
    @portal = Current.account.portals.build(portal_params.merge(live_chat_widget_params))
    @portal.custom_domain = parsed_custom_domain
    process_attached_logo if params[:blob_id].present?
    @portal.save!
  end

  def update
    # Keep upstream's row lock and config merge, but validate the logo and the
    # other attributes together before saving either. Let RecordInvalid escape
    # the transaction so the standard validation response is rendered after rollback.
    @portal.with_lock do
      @portal.assign_attributes(portal_params.merge(live_chat_widget_params)) if params[:portal].present?
      process_attached_logo if params[:blob_id].present?
      @portal.save!
    end
  end

  def process_attached_logo
    blob = ActiveStorage::Blob.find_signed(params[:blob_id].to_s)
    @portal.logo = blob if blob
  end
end
