# frozen_string_literal: true

module Toybaco::Security::PortalLogoValidation
  def self.prepended(base)
    base.validate :toybaco_logo_rejection
  end

  # ActiveStorage's attach, including onboarding URL imports, uses this writer.
  # Check bytes before creating any attachment change that could upload them.
  def logo=(attachable)
    @toybaco_rejected_logo = nil
    if attachable.blank?
      super
    else
      super(Toybaco::Security::AttachmentInput.new(attachable, policy: Toybaco::Security::AvatarPolicy).checked)
    end
  rescue Toybaco::Security::AttachmentPolicy::Rejected => e
    # Preserve an existing logo and report the rejection on the next save.
    @toybaco_rejected_logo = e.message
  end

  private

  def toybaco_logo_rejection
    errors.add(:logo, @toybaco_rejected_logo) if @toybaco_rejected_logo
  end
end
