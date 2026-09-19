# frozen_string_literal: true

require 'minitest/autorun'
require 'mail'
require_relative '../overlay/app/lib/toybaco/connections/microsoft_outgoing'

class ToybacoMicrosoftOutgoingTest < Minitest::Test
  Outgoing = Toybaco::Connections::MicrosoftOutgoing
  Api = Toybaco::Connections::MicrosoftApi

  class FakeApi
    attr_accessor :bad_ack
    attr_reader :calls

    def initialize
      @calls = []
    end

    def add_attachment(**args)
      @calls << [:small, args]
      { 'id' => 'small-file' }
    end

    def upload_session(**args)
      @calls << [:session, args]
      { 'uploadUrl' => 'https://outlook.office.com/fixture/AttachmentSessions(session)?authtoken=fixture' }
    end

    def upload_chunk(**args)
      @calls << [:chunk, args]
      offset = args[:offset] + args[:bytes].bytesize
      return { status: 200, data: { 'nextExpectedRanges' => ['1-'] } } if bad_ack

      { status: offset == args[:total] ? 201 : 200, data: { 'nextExpectedRanges' => ["#{offset}-"] } }
    end
  end

  def setup
    @mail = Mail.new
    @mail.from = 'store@example.test'
    @mail.to = 'customer@example.test'
    @mail.cc = 'colleague@example.test'
    @mail.reply_to = 'store@example.test'
    @mail.subject = 'Reply'
    @mail.html_part = Mail::Part.new { content_type 'text/html; charset=UTF-8'; body '<p>Reply<img src="cid:picture"></p>' }
    @api = FakeApi.new
  end

  def outgoing
    Outgoing.new(@mail, api: @api, access_token: 'fixture')
  end

  def test_recipient_body_and_inline_image_survive_mail_rendering
    @mail.attachments.inline['image.png'] = 'img'
    @mail.attachments.first.content_id = 'picture'
    payload = outgoing.message
    assert_equal 'HTML', payload.dig('body', 'contentType')
    assert_includes payload.dig('body', 'content'), 'cid:picture'
    assert_equal [{ 'emailAddress' => { 'address' => 'customer@example.test' } }], payload['toRecipients']
    assert_equal [{ 'emailAddress' => { 'address' => 'colleague@example.test' } }], payload['ccRecipients']
    outgoing.attach('draft')
    assert_equal 'picture', @api.calls.first.last.dig(:file, :content_id)
    assert_equal true, @api.calls.first.last.dig(:file, :inline)
    assert_equal 'img', @api.calls.first.last[:bytes]
  end

  def test_large_attachment_uses_sequential_chunks_with_exact_total
    @mail.attachments['large.bin'] = 'x' * 5_000_000
    outgoing.attach('draft')
    assert_equal 1, @api.calls.count { |kind, _| kind == :session }
    chunks = @api.calls.select { |kind, _| kind == :chunk }.map(&:last)
    assert_equal [0, Outgoing::CHUNK_BYTES], chunks.map { |chunk| chunk[:offset] }
    assert_equal 5_000_000, chunks.sum { |chunk| chunk[:bytes].bytesize }
    assert chunks.all? { |chunk| chunk[:total] == 5_000_000 && chunk[:bytes].bytesize < 4_000_000 }
  end

  def test_wrong_acknowledged_range_stops_before_later_uploads_or_send
    @mail.attachments['large.bin'] = 'x' * 5_000_000
    @api.bad_ack = true
    assert_raises(Api::Error) { outgoing.attach('draft') }
    assert_equal 1, @api.calls.count { |kind, _| kind == :chunk }
  end
end
