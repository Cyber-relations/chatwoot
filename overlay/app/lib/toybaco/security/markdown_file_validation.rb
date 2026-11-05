# frozen_string_literal: true

module Toybaco::Security::MarkdownFileValidation
  private

  def prepare_markdown_document
    Toybaco::Security::MarkdownDocumentPolicy.identify!(StringIO.new(markdown_content))
    super
  rescue Toybaco::Security::AttachmentPolicy::Rejected => e
    errors.add(:markdown_content, e.message)
    throw :abort
  end
end
