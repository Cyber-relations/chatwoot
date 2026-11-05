# frozen_string_literal: true

require_relative 'mp4_media_type'
require_relative 'ooxml_media_type'

module Toybaco::Security::AttachmentPolicy
  class Rejected < StandardError; end

  ALLOWED_TYPES = %w[
    image/jpeg image/png image/gif image/webp image/heic image/heif image/heic-sequence image/heif-sequence
    application/pdf application/zip application/x-zip-compressed
    application/msword application/vnd.ms-excel application/vnd.ms-powerpoint application/rtf text/rtf
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.openxmlformats-officedocument.wordprocessingml.template
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    application/vnd.openxmlformats-officedocument.spreadsheetml.template
    application/vnd.openxmlformats-officedocument.presentationml.presentation
    application/vnd.openxmlformats-officedocument.presentationml.template
    application/vnd.openxmlformats-officedocument.presentationml.slideshow
    application/vnd.ms-word.document.macroenabled.12 application/vnd.ms-word.template.macroenabled.12
    application/vnd.ms-excel.sheet.macroenabled.12 application/vnd.ms-excel.template.macroenabled.12
    application/vnd.ms-excel.sheet.binary.macroenabled.12
    application/vnd.ms-powerpoint.presentation.macroenabled.12 application/vnd.ms-powerpoint.template.macroenabled.12
    application/vnd.ms-powerpoint.slideshow.macroenabled.12
    application/vnd.oasis.opendocument.text application/vnd.oasis.opendocument.text-template
    application/vnd.oasis.opendocument.text-master application/vnd.oasis.opendocument.spreadsheet
    application/vnd.oasis.opendocument.spreadsheet-template application/vnd.oasis.opendocument.presentation
    application/vnd.oasis.opendocument.presentation-template application/vnd.oasis.opendocument.graphics
    application/vnd.oasis.opendocument.graphics-template application/vnd.oasis.opendocument.formula
    text/plain text/csv
    audio/mpeg audio/mp3 audio/mp4 audio/x-m4a audio/aac audio/x-aac audio/wav audio/x-wav audio/vnd.wave audio/ogg
    audio/opus audio/vorbis audio/speex audio/x-oggflac audio/x-oggpcm
    video/mp4 video/quicktime video/webm audio/webm video/3gpp audio/3gpp application/ogg
  ].freeze
  OLE_TYPES = %w[application/x-ole-storage application/x-tika-msoffice application/vnd.ms-office].freeze
  OFFICE_STREAMS = { 'WordDocument' => 'application/msword', 'Workbook' => 'application/vnd.ms-excel',
                     'Book' => 'application/vnd.ms-excel', 'PowerPoint Document' => 'application/vnd.ms-powerpoint' }.freeze

  def self.limit
    megabytes = GlobalConfigService.load('MAXIMUM_FILE_UPLOAD_SIZE', 40).to_i
    (megabytes.positive? ? megabytes : 40).megabytes
  end

  def self.validate_size!(size)
    raise Rejected, 'File size is too big' if size > limit
    raise Rejected, 'File size is invalid' if size.negative?
  end

  # Neither name nor declared_type is passed to Marcel: both are client input.
  # ZIP-based Office/ODF documents may identify as ZIP, which is also allowed.
  def self.identify!(io)
    validate_size!(io.size)
    io.rewind
    type = Marcel::MimeType.for(io).downcase
    type = Toybaco::Security::OoxmlMediaType.for(io) if type == 'application/x-tika-ooxml'
    type = Toybaco::Security::Mp4MediaType.for(io) || type if %w[video/mp4 audio/mp4 audio/x-m4a].include?(type)
    type = office_type(io) if OLE_TYPES.include?(type)
    type = plain_text_type(io) if %w[application/octet-stream text/plain text/csv].include?(type)
    raise Rejected, 'File type not supported' unless ALLOWED_TYPES.include?(type)

    type
  ensure
    io.rewind
  end

  def self.office_type(io)
    io.rewind
    bytes = io.read
    OFFICE_STREAMS.each do |stream, type|
      return type if bytes.include?(stream.encode(Encoding::UTF_16LE).b)
    end
    nil
  end

  # Marcel has no magic for ordinary text. Validate the bytes, including the
  # entire file, before treating an unrecognised stream as text. Support UTF-8,
  # BOM-marked UTF-16 and Windows-31J (common for Japanese CSV exports).
  # Markup is deliberately excluded, even when disguised as .txt or .csv.
  def self.plain_text_type(io)
    io.rewind
    text = decode_text(io.read)
    return unless text
    return if text.match?(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/)
    return if text.match?(%r{\A[\s\uFEFF]*<(?:!--|!doctype\b|\?[a-z][\w:.-]*\b|/?[a-z][\w:.-]*(?:\s[^<>]*|/?)>)}i)

    'text/plain'
  end

  def self.decode_text(bytes)
    return bytes.byteslice(2..).force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8) if bytes.start_with?("\xFF\xFE".b)
    return bytes.byteslice(2..).force_encoding(Encoding::UTF_16BE).encode(Encoding::UTF_8) if bytes.start_with?("\xFE\xFF".b)

    text = bytes.dup.force_encoding(Encoding::UTF_8)
    return text if text.valid_encoding?

    bytes.force_encoding(Encoding::Windows_31J).encode(Encoding::UTF_8)
  rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
    nil
  end
end
