# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../overlay/app/lib/toybaco/connections/gmail_parts'

class ToybacoGmailPartsTest < Minitest::Test
  Parts = Toybaco::Connections::GmailParts
  Error = Toybaco::Connections::GmailApi::Error

  class FakeApi
    attr_reader :calls
    attr_accessor :response

    def initialize
      @calls = []
    end

    def attachment(**args)
      @calls << args
      raise response if response.is_a?(Exception)

      response
    end
  end

  def body(text)
    { 'size' => text.bytesize, 'data' => Base64.urlsafe_encode64(text) }
  end

  def text_part(text, type = 'text/plain')
    { 'mimeType' => type, 'headers' => [{ 'name' => 'Content-Type', 'value' => "#{type}; charset=UTF-8" }], 'body' => body(text) }
  end

  def file_part(size: 3, id: 'attachment_1', name: 'menu.pdf')
    { 'mimeType' => 'application/pdf', 'filename' => name, 'body' => { 'size' => size, 'attachmentId' => id } }
  end

  def build(*parts, **options)
    @api = FakeApi.new
    @data = { 'id' => 'provider_1', 'payload' => {
      'mimeType' => 'multipart/mixed', 'headers' => [
        { 'name' => 'From', 'value' => 'Customer <customer@example.test>' },
        { 'name' => 'To', 'value' => 'store@example.test' },
        { 'name' => 'Message-ID', 'value' => '<customer-1@example.test>' },
        { 'name' => 'Subject', 'value' => '予約について' }
      ], 'parts' => parts
    } }
    @reader = Parts.new(api: @api, access_token: 'fixture-token', data: @data, **options)
  end

  def test_large_attachment_is_not_fetched_and_japanese_body_is_preserved
    build(text_part('明日予約できますか？'), file_part(size: 25_000_001))
    mail = @reader.mail
    assert_equal '明日予約できますか？', mail.text_part.decoded.force_encoding('UTF-8')
    assert_equal 'customer-1@example.test', mail.message_id
    assert_equal ['customer@example.test'], mail.from
    assert_equal '予約について', mail.subject
    assert_empty @api.calls
    assert_empty mail.attachments
    assert_equal 'file_too_large', @reader.omissions.first['reason']
  end

  def test_small_external_attachment_preserves_exact_binary_bytes
    build(text_part('Body'), file_part)
    @api.response = body("\x00\xFF\x7F".b)
    mail = @reader.mail
    assert_equal "\x00\xFF\x7F".b, mail.attachments.first.decoded
    assert_equal 'menu.pdf', mail.attachments.first.filename
    assert_equal 'provider_1', @api.calls.first[:message_id]
    assert_empty @reader.omissions
  end

  def test_nested_alternatives_and_inline_image_keep_their_identity
    inline = file_part(name: 'photo.png')
    inline['mimeType'] = 'image/png'
    inline['headers'] = [{ 'name' => 'Content-Disposition', 'value' => 'inline; filename="photo.png"' },
                         { 'name' => 'Content-ID', 'value' => '<photo@example.test>' }]
    alternative = { 'mimeType' => 'multipart/alternative', 'parts' => [text_part('Body'), text_part('<p>Body</p>', 'text/html')] }
    build(alternative, inline)
    @api.response = body('PNG')
    mail = @reader.mail
    assert_equal 'Body', mail.text_part.decoded
    assert_equal '<p>Body</p>', mail.html_part.decoded
    assert_equal '<photo@example.test>', mail.attachments.first.content_id
    assert mail.attachments.first.inline?
  end

  def test_missing_attachment_keeps_body_but_temporary_error_does_not_claim_success
    build(text_part('Body'), file_part)
    @api.response = Error.new(404)
    assert_equal 'Body', @reader.mail.text_part.decoded
    assert_equal 'not_available', @reader.omissions.first['reason']
    build(text_part('Body'), file_part)
    @api.response = Error.new(503)
    assert_raises(Error) { @reader.mail }
    assert_empty @reader.omissions
  end

  def test_attachment_count_is_enforced_before_download
    build(text_part('Body'), file_part, file_part(id: 'attachment_2'), attachment_count: 1)
    @api.response = body('pdf')
    assert_equal 1, @reader.mail.attachments.size
    assert_equal 1, @api.calls.size
    assert_equal 'attachment_count', @reader.omissions.first['reason']
  end

  def test_invalid_base64_or_size_is_never_silently_saved_as_an_empty_body
    build(text_part('Body'))
    @data['payload']['parts'].first['body']['data'] = 'invalid*'
    assert_raises(Error) { @reader.mail }
    build(text_part('Body'))
    @data['payload']['parts'].first['body']['size'] = 99
    assert_raises(Error) { @reader.mail }
  end

  # 段 2a: 一斉配信・自動送信の見分けに使うヘッダーも残す(値は他のヘッダーと同じく 1 行にする)。許可していないヘッダーは落とす。
  def test_list_and_automation_headers_survive_and_unlisted_headers_are_dropped
    build(text_part('Body'))
    @data['payload']['headers'] += [
      { 'name' => 'List-Unsubscribe', 'value' => "<mailto:leave@example.test>,\r\n <https://example.test/leave>" },
      { 'name' => 'List-Id', 'value' => '<news.example.test>' }, { 'name' => 'List-Post', 'value' => 'NO' },
      { 'name' => 'Precedence', 'value' => 'bulk' }, { 'name' => 'Return-Path', 'value' => '<>' },
      { 'name' => 'X-Auto-Response-Suppress', 'value' => 'All' }, { 'name' => 'X-Spam-Score', 'value' => '9.9' }
    ]
    mail = Mail.read_from_string(@reader.mail.encoded)
    assert_equal '<mailto:leave@example.test>, <https://example.test/leave>', mail['List-Unsubscribe'].value
    assert_equal %w[<news.example.test> bulk All], [mail['List-Id'], mail['Precedence'], mail['X-Auto-Response-Suppress']].map(&:value)
    # The empty Return-Path (<>) is kept; Mail reads it as an empty value.
    refute_nil mail['Return-Path']
    assert_equal '', mail['Return-Path'].value.to_s
    assert_nil mail['List-Post']
    assert_nil mail['X-Spam-Score']
  end

  def test_a_message_containing_only_an_oversized_file_keeps_its_headers
    build(text_part('unused'))
    @data['payload'].merge!(file_part(size: 25_000_001))
    @data['payload'].delete('parts')
    mail = @reader.mail
    assert_equal 'customer-1@example.test', mail.message_id
    assert_equal ['customer@example.test'], mail.from
    assert_empty mail.attachments
    assert_empty @api.calls
    assert_equal 'file_too_large', @reader.omissions.first['reason']
  end
end
