# frozen_string_literal: true

module Toybaco::Security::MarkdownDocumentPolicy
  def self.identify!(io)
    Toybaco::Security::AttachmentPolicy.validate_size!(io.size)
    io.rewind
    text = io.read.force_encoding(Encoding::UTF_8)
    unless text.valid_encoding? && !text.match?(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/) && !markup?(text)
      raise Toybaco::Security::AttachmentPolicy::Rejected, 'File must be Markdown without raw markup'
    end

    'text/markdown'
  ensure
    io.rewind
  end

  # Use the application's Markdown parser so fenced/indented code, escaped
  # tags, autolinks and ordinary angle brackets remain valid Markdown. Raw HTML,
  # SVG, XML, comments and processing instructions are rejected anywhere else.
  def self.markup?(text)
    CommonMarker.render_doc(text.delete_prefix("\uFEFF")).walk do |node|
      return true if %i[html inline_html].include?(node.type)
    end
    false
  end
end
