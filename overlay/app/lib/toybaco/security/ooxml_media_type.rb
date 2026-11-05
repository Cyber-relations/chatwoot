# frozen_string_literal: true

require 'zlib'
require 'nokogiri'
require_relative 'office_zip_directory'

class Toybaco::Security::OoxmlMediaType
  ZIP_TYPE = 'application/zip'
  CONTENT_TYPES_NAMESPACE = 'http://schemas.openxmlformats.org/package/2006/content-types'
  MAIN_PARTS = {
    '/word/document.xml' => %w[application/vnd.openxmlformats-officedocument.wordprocessingml. application/vnd.ms-word.],
    '/xl/workbook.xml' => %w[application/vnd.openxmlformats-officedocument.spreadsheetml. application/vnd.ms-excel.],
    '/xl/workbook.bin' => %w[application/vnd.ms-excel.],
    '/ppt/presentation.xml' => %w[application/vnd.openxmlformats-officedocument.presentationml. application/vnd.ms-powerpoint.]
  }.freeze

  def self.for(io)
    new(io).media_type
  ensure
    io.rewind
  end

  def initialize(io)
    @directory = Toybaco::Security::OfficeZipDirectory.new(io)
  end

  def media_type
    entries = @directory.entries
    entry = entries['[Content_Types].xml']
    return ZIP_TYPE unless entry

    types = main_types(content_types(entry), entries)
    types.one? ? types.first : ZIP_TYPE
  rescue Toybaco::Security::OfficeZipDirectory::Invalid, Zlib::Error, Nokogiri::XML::SyntaxError
    ZIP_TYPE
  end

  private

  def content_types(entry)
    compressed = @directory.compressed_bytes(entry)
    bytes = entry.compression_method.zero? ? compressed : inflate(compressed, entry.compression_method)
    raise Toybaco::Security::OfficeZipDirectory::Invalid unless bytes.bytesize == entry.uncompressed_size && Zlib.crc32(bytes) == entry.crc

    document = Nokogiri::XML(bytes) { |config| config.strict.nonet }
    raise Toybaco::Security::OfficeZipDirectory::Invalid if document.internal_subset

    document
  end

  def inflate(bytes, method)
    raise Toybaco::Security::OfficeZipDirectory::Invalid unless method == 8

    inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
    result = +''.b
    inflater.inflate(bytes) do |chunk|
      size = result.bytesize + chunk.bytesize
      raise Toybaco::Security::OfficeZipDirectory::Invalid if size > Toybaco::Security::OfficeZipDirectory::MAX_MEMBER_BYTES

      result << chunk
    end
    raise Toybaco::Security::OfficeZipDirectory::Invalid unless inflater.finished? && inflater.total_in == bytes.bytesize

    result
  ensure
    inflater&.close
  end

  def main_types(document, entries)
    document.xpath('/ct:Types/ct:Override', 'ct' => CONTENT_TYPES_NAMESPACE).each_with_object([]) do |node, types|
      part = node['PartName']
      next unless MAIN_PARTS.key?(part) && entries.key?(part.delete_prefix('/'))

      type = office_type(node['ContentType'].to_s.downcase, MAIN_PARTS.fetch(part))
      types << type if type
    end.uniq
  end

  def office_type(type, prefixes)
    return unless type.start_with?(*prefixes) && type.match?(/\.main(?:\+xml)?\z/)

    type = type.sub(/\.main(?:\+xml)?\z/, '').sub(/\.macroenabled\z/, '.macroenabled.12')
    type if Toybaco::Security::AttachmentPolicy::ALLOWED_TYPES.include?(type)
  end
end
