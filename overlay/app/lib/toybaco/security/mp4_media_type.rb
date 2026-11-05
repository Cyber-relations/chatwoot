# frozen_string_literal: true

# Marcel identifies MP4 brands, not their tracks. Inspect only box headers and
# moov/trak/mdia/hdlr payloads; never scan media bytes for handler-like strings.
class Toybaco::Security::Mp4MediaType
  class Invalid < StandardError; end

  MAX_BOXES = 4096

  def self.for(io)
    new(io).media_type
  ensure
    io.rewind
  end

  def initialize(io)
    @io = io
    @remaining_boxes = MAX_BOXES
  end

  def media_type
    movies = children(0, @io.size, 'moov')
    tracks = movies.flat_map { |start, finish| children(start, finish, 'trak') }
    handlers = tracks.map { |start, finish| track_handler(start, finish) }
    return 'video/mp4' if handlers.include?('vide')

    'audio/mp4' if handlers.include?('soun')
  rescue Invalid
    nil
  end

  private

  def track_handler(start, finish)
    media = children(start, finish, 'mdia')
    raise Invalid unless media.one?

    handlers = children(*media.first, 'hdlr')
    raise Invalid unless handlers.one?

    start, finish = handlers.first
    raise Invalid if finish - start < 24

    header = read_at(start, 12, finish)
    raise Invalid unless header.start_with?("\x00\x00\x00\x00".b)

    header.byteslice(8, 4)
  end

  def children(start, finish, wanted)
    found = []
    while start < finish
      @remaining_boxes -= 1
      raise Invalid if @remaining_boxes.negative?

      type, body, box_end = box_at(start, finish)
      found << [body, box_end] if type == wanted
      start = box_end
    end
    found
  end

  def box_at(start, finish)
    size, type = read_at(start, 8, finish).unpack('Na4')
    header_size = size == 1 ? 16 : 8
    size = read_at(start + 8, 8, finish).unpack1('Q>') if size == 1
    size = finish - start if size.zero?
    raise Invalid if size < header_size || size > finish - start

    [type, start + header_size, start + size]
  end

  def read_at(offset, length, finish)
    raise Invalid if offset + length > finish

    @io.seek(offset)
    bytes = @io.read(length)
    raise Invalid unless bytes && bytes.bytesize == length

    bytes
  end
end
