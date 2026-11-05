# frozen_string_literal: true

# A bounded, read-only ZIP directory reader. No extraction, ZIP64 expansion or
# archive-sized allocation: unsupported/ambiguous containers remain ZIP files.
class Toybaco::Security::OfficeZipDirectory
  class Invalid < StandardError; end

  MAX_ENTRIES = 4096
  MAX_DIRECTORY_BYTES = 1024 * 1024
  MAX_MEMBER_BYTES = 256 * 1024
  END_SIGNATURE = "PK\x05\x06".b.freeze
  Entry = Struct.new(:name, :flags, :compression_method, :crc, :compressed_size, :uncompressed_size, :offset, keyword_init: true)

  def initialize(io)
    @io = io
  end

  def entries
    count, size, @directory_offset = directory_location
    raise Invalid if count > MAX_ENTRIES || size > MAX_DIRECTORY_BYTES

    bytes = read_at(@directory_offset, size)
    result = {}
    offset = 0
    count.times { offset = consume_entry(bytes, offset, result) }
    raise Invalid unless offset == bytes.bytesize

    result
  end

  def compressed_bytes(entry)
    raise Invalid if entry.uncompressed_size > MAX_MEMBER_BYTES || entry.compressed_size > MAX_MEMBER_BYTES || entry.flags.anybits?(1)

    start = member_data_offset(entry)
    raise Invalid if start + entry.compressed_size > @directory_offset

    read_at(start, entry.compressed_size)
  end

  private

  def member_data_offset(entry)
    header = read_at(entry.offset, 30)
    raise Invalid unless header.start_with?("PK\x03\x04".b) && header.byteslice(6, 4).unpack('v2') == [entry.flags, entry.compression_method]

    name_size, extra_size = header.byteslice(26, 4).unpack('v2')
    raise Invalid unless read_at(entry.offset + 30, name_size) == entry.name

    entry.offset + 30 + name_size + extra_size
  end

  def directory_location
    tail, tail_start, index = directory_tail
    disk, directory_disk, disk_count, count, size, offset, comment_size = tail.byteslice(index + 4, 18).unpack('v4V2v')
    raise Invalid unless disk.zero? && directory_disk.zero? && disk_count == count
    raise Invalid unless index + 22 + comment_size == tail.bytesize && offset + size == tail_start + index

    [count, size, offset]
  end

  def directory_tail
    tail_start = [@io.size - 65_557, 0].max
    tail = read_at(tail_start, @io.size - tail_start)
    index = tail.rindex(END_SIGNATURE)
    raise Invalid unless index && tail.bytesize - index >= 22

    [tail, tail_start, index]
  end

  def consume_entry(bytes, offset, entries)
    header = bytes.byteslice(offset, 46)
    raise Invalid unless header && header.bytesize == 46 && header.start_with?("PK\x01\x02".b)

    name_size, extra_size, comment_size, disk = header.byteslice(28, 8).unpack('v4')
    length = 46 + name_size + extra_size + comment_size
    raise Invalid unless disk.zero? && offset + length <= bytes.bytesize

    entry = entry_from(header, bytes.byteslice(offset + 46, name_size))
    raise Invalid if entries.key?(entry.name)

    entries[entry.name] = entry
    offset + length
  end

  def entry_from(bytes, name)
    flags, compression_method = bytes.byteslice(8, 4).unpack('v2')
    crc, compressed_size, uncompressed_size = bytes.byteslice(16, 12).unpack('V3')
    Entry.new(name: name, flags: flags, compression_method: compression_method, crc: crc,
              compressed_size: compressed_size, uncompressed_size: uncompressed_size, offset: bytes.byteslice(42, 4).unpack1('V'))
  end

  def read_at(offset, length)
    raise Invalid if offset.negative? || offset + length > @io.size

    @io.seek(offset)
    bytes = @io.read(length)
    raise Invalid unless bytes && bytes.bytesize == length

    bytes
  end
end
