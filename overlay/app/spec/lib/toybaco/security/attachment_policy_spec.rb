# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::Security::AttachmentPolicy do
  include_context 'without toybaco network connections'

  def mp4_box(type, payload)
    [payload.bytesize + 8, type].pack('Na4') + payload
  end

  def mp4_track(handler)
    header = mp4_box('hdlr', ("\x00" * 8) + handler + ("\x00" * 12))
    mp4_box('trak', mp4_box('mdia', header))
  end

  describe '.identify!' do
    ["name,email\nCustomer <customer@example.test>,customer@example.test\n", 'x<y', '<customer@example.test>'].each do |text|
      it "preserves ordinary text #{text.inspect}" do
        io = StringIO.new(text)

        expect(described_class.identify!(io)).to eq('text/plain')
        expect(io.read).to eq(text)
      end
    end

    ['<html><body>blocked</body></html>', '<svg xmlns="http://www.w3.org/2000/svg"/>',
     " \n<!DOCTYPE html><html></html>", "\uFEFF \n<?xml version=\"1.0\"?><data/>",
     '  <custom-root>blocked</custom-root>', '  <!-- comment --><script>blocked()</script>'].each do |text|
      it "rejects a markup document beginning #{text[0, 25].inspect}" do
        expect { described_class.identify!(StringIO.new(text)) }.to raise_error(described_class::Rejected, /type not supported/)
      end
    end

    it 'rejects UTF-16 markup after decoding' do
      bytes = "\xFF\xFE".b + '  <svg xmlns="http://www.w3.org/2000/svg"/>'.encode(Encoding::UTF_16LE).b

      expect { described_class.identify!(StringIO.new(bytes)) }.to raise_error(described_class::Rejected, /type not supported/)
    end
  end

  describe '.identify! for MP4 containers' do
    let(:ftyp) { mp4_box('ftyp', "isom#{[0].pack('N')}isommp42") }
    let(:audio_movie) { mp4_box('moov', mp4_track('soun')) }

    # Generated offline with ffmpeg: 0.12s 8kHz sine, AAC 16k, -f mp4
    # -brand isom / -brand mp42. mp42 also uses -movflags +faststart.
    %w[isom mp42].each do |brand|
      it "identifies real audio-only #{brand} bytes as audio despite Marcel's video detection" do
        bytes = Rails.root.join('spec/assets/toybaco/attachment_formats', "audio-#{brand}.m4a").binread
        io = StringIO.new(bytes)

        expect(bytes.byteslice(8, 4)).to eq(brand)
        expect(Marcel::MimeType.for(io)).to eq('video/mp4')
        expect(described_class.identify!(io)).to eq('audio/mp4')
        expect(io.pos).to eq(0)
      end
    end

    # 0.2s 16x16 black H.264 + AAC; audio mapped before video; -brand mp42 -movflags +faststart.
    it 'keeps a real MP4 with both audio and video tracks classified as video' do
      io = File.open(Rails.root.join('spec/assets/toybaco/attachment_formats/video-mp42.mp4'), 'rb')
      expect(described_class.identify!(io)).to eq('video/mp4')
      expect(io.pos).to eq(0)
    ensure
      io&.close
    end

    it 'handles extended-size movie boxes' do
      track = mp4_track('soun')
      movie = [1, 'moov', track.bytesize + 16].pack('Na4Q>') + track

      expect(described_class.identify!(StringIO.new(ftyp + movie))).to eq('audio/mp4')
    end

    it 'handles a movie box extending to the end of the file' do
      movie = [0, 'moov'].pack('Na4') + mp4_track('soun')

      expect(described_class.identify!(StringIO.new(ftyp + movie))).to eq('audio/mp4')
    end

    it 'does not interpret handler-like bytes in media data as tracks' do
      io = StringIO.new(ftyp + mp4_box('mdat', audio_movie))

      expect(described_class.identify!(io)).to eq('video/mp4')
    end

    it 'examines every movie rather than stopping at the first audio track' do
      io = StringIO.new(ftyp + audio_movie + mp4_box('moov', mp4_track('vide')))

      expect(described_class.identify!(io)).to eq('video/mp4')
    end

    it 'keeps the detected type when another track has no handler' do
      movie = mp4_box('moov', mp4_track('soun') + mp4_box('trak', mp4_box('mdia', '')))

      expect(described_class.identify!(StringIO.new(ftyp + movie))).to eq('video/mp4')
    end

    it 'keeps the detected type for a truncated handler' do
      movie = mp4_box('moov', mp4_box('trak', mp4_box('mdia', mp4_box('hdlr', "#{"\x00" * 8}soun"))))

      expect(described_class.identify!(StringIO.new(ftyp + movie))).to eq('video/mp4')
    end

    [[4, 'free'].pack('Na4'), [100, 'free'].pack('Na4'), [1, 'free'].pack('Na4'), 'trailing'].each_with_index do |invalid, index|
      it "does not reclassify an incomplete box tree #{index + 1}" do
        io = StringIO.new(ftyp + audio_movie + invalid)

        expect(described_class.identify!(io)).to eq('video/mp4')
        expect(io.pos).to eq(0)
      end
    end

    it 'bounds box inspection for adversarial containers' do
      stub_const('Toybaco::Security::Mp4MediaType::MAX_BOXES', 8)
      io = StringIO.new(ftyp + (mp4_box('free', '') * 8) + audio_movie)

      expect(described_class.identify!(io)).to eq('video/mp4')
      expect(io.pos).to eq(0)
    end
  end
end
