# frozen_string_literal: true

module Toybaco::Security::AvatarValidation
  def self.prepended(base)
    # A rejected assignment creates no ActiveStorage change, so the upstream
    # avatar.changed? validation condition alone would miss it.
    base.validate :toybaco_avatar_rejection
  end

  def avatar=(attachable)
    @toybaco_rejected_avatar = nil
    if attachable.blank?
      super
    else
      super(Toybaco::Security::AttachmentInput.new(attachable, policy: Toybaco::Security::AvatarPolicy).checked)
    end
  rescue Toybaco::Security::AttachmentPolicy::Rejected => e
    # Keep an existing avatar and never enqueue/store rejected bytes.
    @toybaco_rejected_avatar = e.message
  end

  private

  def toybaco_avatar_rejection
    errors.add(:avatar, @toybaco_rejected_avatar) if @toybaco_rejected_avatar
  end
end
