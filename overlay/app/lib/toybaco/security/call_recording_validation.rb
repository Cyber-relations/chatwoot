# frozen_string_literal: true

module Toybaco::Security::CallRecordingValidation
  # ActiveStorage's attach also calls this writer. Inspect before it can create
  # an attachment change or upload, including provider jobs and existing blobs.
  def recording=(attachable)
    if attachable.blank?
      super
    else
      super(Toybaco::Security::AttachmentInput.new(attachable, policy: Toybaco::Security::CallRecordingPolicy).checked)
    end
  end
end
