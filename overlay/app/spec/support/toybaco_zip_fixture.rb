# frozen_string_literal: true

require 'zlib'

# Deterministic ZIP bytes for container boundary tests; no external ZIP tools.
module ToybacoZipFixture
  def self.build(entries, deflate: false)
    local = +''.b
    directory = +''.b
    entries.each do |name, body|
      append_entry(local, directory, name, body, deflate: deflate)
    end
    ending = [0x06054b50, 0, 0, entries.size, entries.size, directory.bytesize, local.bytesize, 0].pack('Vv4V2v')
    local + directory + ending
  end

  def self.append_entry(local, directory, name, body, deflate:)
    offset = local.bytesize
    compressed = deflate ? compress(body) : body.b
    fields = [deflate ? 8 : 0, 0, 0, Zlib.crc32(body), compressed.bytesize, body.bytesize]
    local << [0x04034b50, 20, 0, *fields, name.bytesize, 0].pack('Vv5V3v2') << name << compressed
    directory << [0x02014b50, 20, 20, 0, *fields, name.bytesize, 0, 0, 0, 0, 0, offset].pack('Vv6V3v5V2') << name
  end
  private_class_method :append_entry

  def self.compress(bytes)
    compressor = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
    compressor.deflate(bytes, Zlib::FINISH)
  ensure
    compressor&.close
  end

  def self.content_types(part, type, padding: 0)
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <!--#{'padding ' * padding}-->
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/#{part}" ContentType="#{type}"/>
      </Types>
    XML
  end
end
