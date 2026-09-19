# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../overlay/app/lib/toybaco/connections/microsoft_parts'

class ToybacoMicrosoftPartsTest < Minitest::Test
  Parts = Toybaco::Connections::MicrosoftParts
  Api = Toybaco::Connections::MicrosoftApi

  class FakeApi
    attr_accessor :pages, :files, :inline_files
    attr_reader :calls

    def initialize
      @pages, @files, @inline_files, @calls = [], {}, {}, []
    end

    def attachments(**args)
      @calls << [:list, args]
      @pages.shift || { 'value' => [] }
    end

    def attachment(**args)
      @calls << [:file, args]
      value = @files.fetch(args[:id])
      raise value if value.is_a?(Exception)

      { body: value }
    end

    def attachment_details(**args)
      @calls << [:inline, args]
      @inline_files.fetch(args[:id])
    end
  end

  def setup
    @api = FakeApi.new
    @data = { 'id' => 'ProviderID=', 'internetMessageId' => '<mail@example.test>', 'subject' => 'Fixture',
              'from' => { 'emailAddress' => { 'address' => 'customer@example.test' } },
              'toRecipients' => [{ 'emailAddress' => { 'address' => 'store@example.test' } }],
              'receivedDateTime' => '2026-09-19T00:00:00Z', 'body' => { 'contentType' => 'Text', 'content' => 'Keep this body.' } }
  end

  def file(id, size: 3, inline: false, type: '#microsoft.graph.fileAttachment')
    { 'id' => id, 'name' => id + '.bin', 'size' => size, 'contentType' => 'application/octet-stream', 'isInline' => inline, '@odata.type' => type }
  end

  def parts(**options)
    Parts.new(api: @api, access_token: 'fixture', data: @data, **options)
  end

  def test_plain_body_and_thread_headers_survive_with_binary_attachment
    @data['internetMessageHeaders'] = [
      { 'name' => 'In-Reply-To', 'value' => '<earlier@example.test>' },
      { 'name' => 'Message-ID', 'value' => '<forged@example.test>' },
      { 'name' => 'Content-Type', 'value' => 'multipart/mixed; boundary=unrelated' }
    ]
    @api.pages = [{ 'value' => [file('one')] }]
    @api.files['one'] = "\x00\xff\x01".b
    raw = Mail.read_from_string(parts.mail.encoded)
    assert_equal 'mail@example.test', raw.message_id
    assert_equal 'earlier@example.test', raw.in_reply_to
    assert_equal ['customer@example.test'], raw.from
    assert_equal ['store@example.test'], raw.to
    assert_equal 'Keep this body.', raw.text_part.decoded
    assert_equal "\x00\xff\x01".b, raw.attachments.first.decoded
  end

  def test_inline_images_are_checked_even_when_has_attachments_is_false
    @data['hasAttachments'] = false
    @data['body'] = { 'contentType' => 'HTML', 'content' => '<p>Keep<img src="cid:picture-id"></p>' }
    @api.pages = [{ 'value' => [file('picture', inline: true)] }]
    @api.inline_files['picture'] = { 'id' => 'picture', 'contentId' => 'picture-id', 'contentBytes' => Base64.strict_encode64('img') }
    raw = Mail.read_from_string(parts.mail.encoded)
    assert_includes raw.html_part.decoded, 'cid:picture-id'
    assert_equal '<picture-id>', raw.attachments.first.content_id
    assert raw.attachments.first.inline?
    assert_equal 'img', raw.attachments.first.decoded
    assert_equal 1, @api.calls.count { |kind, _| kind == :inline }
    assert_equal 0, @api.calls.count { |kind, _| kind == :file }
  end

  def test_large_or_excess_attachments_are_omitted_before_downloading_and_body_remains
    @api.pages = [{ 'value' => [file('huge', size: 25_000_001, inline: true), file('small'), file('extra')] }]
    @api.files['small'] = 'abc'
    result = parts(attachment_count: 1)
    mail = result.mail
    assert_equal 'Keep this body.', mail.text_part.decoded
    assert_equal ['file_too_large', 'attachment_count'], result.omissions.map { |item| item['reason'] }
    assert_equal ['small'], @api.calls.select { |kind, _| kind == :file }.map { |_, args| args[:id] }
    assert_empty @api.calls.select { |kind, _| kind == :inline }
  end

  def test_total_download_bound_prevents_many_large_files_from_exhausting_worker_memory
    @api.pages = [{ 'value' => [file('first', size: 13_000_000), file('second', size: 13_000_000)] }]
    @api.files['first'] = 'x' * 13_000_000
    result = parts
    mail = result.mail
    assert_equal 1, mail.attachments.length
    assert_equal 'second.bin', result.omissions.first['name']
    assert_equal 1, @api.calls.count { |kind, _| kind == :file }
  end

  def test_removed_or_reference_attachment_does_not_prevent_incoming_body
    @api.pages = [{ 'value' => [file('gone'), file('reference', type: '#microsoft.graph.referenceAttachment')] }]
    @api.files['gone'] = Api::Error.new(404)
    result = parts
    assert_equal 'Keep this body.', result.mail.text_part.decoded
    assert_equal 2, result.omissions.length
    assert result.omissions.all? { |item| item['reason'] == 'not_available' }
  end

  def test_provider_transient_failure_does_not_silently_drop_the_attachment
    @api.pages = [{ 'value' => [file('retry')] }]
    @api.files['retry'] = Api::Error.new(503)
    result = parts
    assert_equal 503, assert_raises(Api::Error) { result.mail }.status
    assert_empty result.omissions
  end

  def test_invalid_inline_contents_or_header_injection_are_rejected
    [{ 'contentBytes' => 'invalid!', 'contentId' => 'cid' },
     { 'contentBytes' => Base64.strict_encode64('abc'), 'contentId' => "cid\r\nBcc: another@example.test" }].each do |invalid|
      @api.pages = [{ 'value' => [file('one', inline: true)] }]
      @api.inline_files['one'] = invalid.merge('id' => 'one')
      assert_raises(Api::Error) { parts.mail }
    end
  end

  def test_attachment_pagination_deduplicates_and_detects_provider_loops
    @api.pages = [{ 'value' => [file('one')], '@odata.nextLink' => 'next' }, { 'value' => [file('one'), file('two')] }]
    @api.files = { 'one' => 'abc', 'two' => 'def' }
    assert_equal 2, parts.mail.attachments.length
    assert_equal 2, @api.calls.count { |kind, _| kind == :file }
    @api.pages = [{ 'value' => [], '@odata.nextLink' => 'loop' }, { 'value' => [], '@odata.nextLink' => 'loop' }]
    assert_raises(Api::Error) { parts.mail }
  end

  def test_missing_internet_id_has_stable_provider_specific_fallback
    @data.delete('internetMessageId')
    first = parts.message_id
    assert_equal first, parts.message_id
    assert_match(/\Amicrosoft-[a-f0-9]{64}@toybaco.invalid\z/, first)
    @data['id'] = 'OtherProviderID='
    refute_equal first, parts.message_id
  end
end
