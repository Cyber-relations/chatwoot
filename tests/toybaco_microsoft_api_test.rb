# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../overlay/app/lib/toybaco/connections/microsoft_draft_api'

class ToybacoMicrosoftApiTest < Minitest::Test
  Api = Toybaco::Connections::MicrosoftApi
  Auth = Toybaco::Connections::MicrosoftAuthorizationApi
  Draft = Toybaco::Connections::MicrosoftDraftApi
  Transport = Toybaco::Connections::MicrosoftTransport
  UPLOAD = "https://outlook.office.com/api/v1.0/Users('fixture')/Messages('draft')/AttachmentSessions('session')?authtoken=fixture"

  def setup
    @calls = []
    @response = { status: 200, body: '{}' }
    @transport = lambda do |**args|
      @calls << args
      raise @response if @response.is_a?(Exception)

      @response
    end
    @api = Api.new(transport: @transport)
    @draft = Draft.new(transport: @transport)
    @auth = Auth.new(client_id: 'fixture-client', client_secret: 'fixture-secret',
                     redirect_uri: 'https://app.example.test/toybaco/connections/microsoft/callback', transport: @transport)
  end

  def token(**changes)
    data = { 'access_token' => 'fixture-access', 'refresh_token' => 'fixture-refresh', 'token_type' => 'Bearer',
             'expires_in' => 3600, 'scope' => 'User.Read Mail.ReadWrite Mail.Send' }.merge(changes.transform_keys(&:to_s))
    @response = { status: 200, body: JSON.generate(data) }
  end

  def test_authorize_uses_code_pkce_and_own_mail_delegated_permissions
    uri = URI(@auth.authorization_url(state: 'a' * 64, challenge: 'b' * 43))
    params = URI.decode_www_form(uri.query).to_h
    assert_equal 'login.microsoftonline.com', uri.host
    assert_equal 'code', params['response_type']
    assert_equal 'S256', params['code_challenge_method']
    assert_equal 'select_account', params['prompt']
    assert_equal Auth::SCOPES, params['scope'].split
    refute params.values.include?('fixture-secret')
    assert_raises(ArgumentError) { @auth.authorization_url(state: 'bad', challenge: 'b' * 43) }
  end

  def test_exchange_binds_verifier_and_requires_renewable_complete_permissions
    token
    result = @auth.exchange(code: 'fixture-code', verifier: 'fixture-verifier')
    assert_equal 'fixture-refresh', result['refresh_token']
    form = URI.decode_www_form(@calls.last[:body]).to_h
    assert_equal 'authorization_code', form['grant_type']
    assert_equal 'fixture-verifier', form['code_verifier']
    assert_equal 'fixture-secret', form['client_secret']
    token(scope: 'User.Read Mail.Send')
    error = assert_raises(Api::Error) { @auth.exchange(code: 'code', verifier: 'verifier') }
    assert error.authorization_failure?
    token(refresh_token: nil)
    assert_raises(Api::Error) { @auth.exchange(code: 'code', verifier: 'verifier') }
  end

  def test_refresh_accepts_rotated_or_unchanged_refresh_token_and_full_scope_urls
    token(refresh_token: nil, scope: Auth::SCOPES.join(' '))
    assert_equal 'fixture-access', @auth.refresh(refresh_token: 'old')['access_token']
    assert_equal 'refresh_token', URI.decode_www_form(@calls.last[:body]).to_h['grant_type']
    token(refresh_token: 'rotated')
    assert_equal 'rotated', @auth.refresh(refresh_token: 'old')['refresh_token']
  end

  def test_provider_error_never_exposes_description_or_token
    @response = { status: 400, body: JSON.generate('error' => 'invalid_grant', 'error_description' => 'fixture-private-detail') }
    error = assert_raises(Api::Error) { @auth.refresh(refresh_token: 'private-token') }
    assert error.authorization_failure?
    refute_includes error.message, 'fixture-private-detail'
    refute_includes error.message, 'private-token'
    assert_equal 1, @calls.length
  end

  def test_invalid_token_response_and_duplicate_keys_fail_closed
    ['[]', '{"access_token":"one","access_token":"two"}', 'invalid'].each do |body|
      @response = { status: 200, body: body }
      assert_raises(Api::Error) { @auth.refresh(refresh_token: 'fixture') }
    end
    token(token_type: 'other')
    assert_raises(Api::Error) { @auth.refresh(refresh_token: 'fixture') }
  end

  def test_message_uses_immutable_id_and_escaped_resource_id
    @api.message(access_token: 'fixture', id: 'Ab+/=')
    call = @calls.last
    assert_equal '/v1.0/me/messages/Ab%2B%2F%3D', URI(call[:url]).path
    assert_includes call[:headers]['Prefer'], 'IdType="ImmutableId"'
    assert_includes URI.decode_www_form(URI(call[:url]).query).to_h['$select'], 'sentDateTime'
    assert_raises(ArgumentError) { @api.message(access_token: 'fixture', id: '../users') }
  end

  def test_delta_preserves_opaque_cursor_and_rejects_other_mailbox_folder_or_origin
    cursor = 'https://graph.microsoft.com/v1.0/me/mailFolders/Folder%2B%3D/messages/delta?$deltatoken=a%2Bb'
    @api.delta(access_token: 'fixture', folder_id: 'Folder+=', since: '2026-09-18T00:00:00Z', cursor: cursor)
    assert_equal cursor, @calls.last[:url]
    [cursor.sub('Folder%2B%3D', 'other'), cursor.sub('/me/', '/users/other/'), cursor.sub('graph.microsoft.com', 'evil.example'),
     cursor.sub('https:', 'http:'), cursor + '#fragment', cursor.sub('graph.microsoft.com', 'user@graph.microsoft.com')].each do |bad|
      assert_raises(ArgumentError) do
        @api.delta(access_token: 'fixture', folder_id: 'Folder+=', since: '2026-09-18T00:00:00Z', cursor: bad)
      end
    end
    assert_equal 1, @calls.length
  end

  def test_initial_delta_is_bounded_at_connection_time_and_attachment_stream_is_capped
    @api.delta(access_token: 'fixture', folder_id: 'folder', since: '2026-09-18T09:00:00+09:00')
    query = URI.decode_www_form(URI(@calls.last[:url]).query).to_h
    assert_equal 'receivedDateTime ge 2026-09-18T00:00:00Z', query['$filter']
    @api.attachment(access_token: 'fixture', message_id: 'mail', id: 'file')
    assert_equal 25_000_000, @calls.last[:max_bytes]
    assert @calls.last[:url].end_with?('/attachments/file/$value')
  end

  def test_retry_after_and_authorization_errors_are_distinct_from_sync_expiry
    @response = { status: 429, body: '{}', retry_after: '45' }
    error = assert_raises(Api::Error) { @api.profile(access_token: 'fixture') }
    assert_equal '45', error.retry_after
    refute error.authorization_failure?
    @response = { status: 410, body: JSON.generate('error' => { 'code' => 'ErrorInvalidSyncStateData' }) }
    error = assert_raises(Api::Error) { @api.profile(access_token: 'fixture') }
    assert_equal 'ErrorInvalidSyncStateData', error.reason
    refute error.authorization_failure?
  end

  def test_reply_creation_retains_immutable_draft_and_does_not_send
    @response = { status: 201, body: JSON.generate('id' => 'draft=', 'isDraft' => true) }
    result = @draft.create_reply(access_token: 'fixture', message_id: 'original', message: { 'body' => { 'contentType' => 'Text', 'content' => 'reply' } })
    assert_equal 'draft=', result['id']
    assert_equal 1, @calls.length
    assert @calls.last[:url].end_with?('/messages/original/createReply')
    assert_equal 'reply', JSON.parse(@calls.last[:body]).dig('message', 'body', 'content')
    @response = { status: 201, body: JSON.generate('id' => 'already-sent', 'isDraft' => false) }
    assert_raises(Api::Error) { @draft.create_reply(access_token: 'fixture', message_id: 'original', message: {}) }
  end

  def test_small_attachment_encoding_and_large_upload_boundary
    @draft.add_attachment(access_token: 'fixture', draft_id: 'draft', file: { name: 'fixture.bin', content_type: 'application/octet-stream' }, bytes: "\x00\xff".b)
    assert_equal "\x00\xff".b, Base64.strict_decode64(JSON.parse(@calls.last[:body])['contentBytes'])
    assert_raises(ArgumentError) do
      @draft.add_attachment(access_token: 'fixture', draft_id: 'draft', file: { name: 'file', content_type: 'application/octet-stream' }, bytes: 'x' * 3_000_000)
    end
    @draft.upload_session(access_token: 'fixture', draft_id: 'draft', file: { name: 'file', content_type: 'application/octet-stream' }, size: 25_000_000)
    assert_equal 25_000_000, JSON.parse(@calls.last[:body]).dig('AttachmentItem', 'size')
    assert_raises(ArgumentError) do
      @draft.upload_session(access_token: 'fixture', draft_id: 'draft', file: { name: 'file', content_type: 'application/octet-stream' }, size: 25_000_001)
    end
  end

  def test_upload_uses_range_without_mailbox_token_and_rejects_redirected_or_wrong_target
    @response = { status: 200, body: JSON.generate('nextExpectedRanges' => ['3-']) }
    result = @draft.upload_chunk(url: UPLOAD, bytes: 'abc', offset: 0, total: 6)
    assert_equal ['3-'], result[:data]['nextExpectedRanges']
    assert_equal 'bytes 0-2/6', @calls.last[:headers]['Content-Range']
    refute @calls.last[:headers].key?('Authorization')
    [UPLOAD.sub('outlook.office.com', 'evil.example'), 'https://graph.microsoft.com/v1.0/me/messages/other', UPLOAD + '#fragment'].each do |url|
      assert_raises(ArgumentError) { @draft.upload_chunk(url: url, bytes: 'abc', offset: 0, total: 6) }
    end
    @response = { status: 302, body: '' }
    assert_raises(Api::Error) { @draft.upload_chunk(url: UPLOAD, bytes: 'abc', offset: 0, total: 6) }
    assert_equal 2, @calls.length
  end

  def test_invalid_ranges_fail_before_upload
    [{ bytes: '', offset: 0, total: 1 }, { bytes: 'abc', offset: -1, total: 3 }, { bytes: 'abc', offset: 2, total: 3 },
     { bytes: 'x' * 4_000_000, offset: 0, total: 4_000_000 }, { bytes: 'a', offset: 0, total: 25_000_001 }].each do |args|
      assert_raises(ArgumentError) { @draft.upload_chunk(url: UPLOAD, **args) }
    end
    assert_empty @calls
  end

  def test_send_reports_acceptance_only_and_never_retries_timeout
    @response = { status: 202, body: '', request_id: 'fixture-receipt' }
    assert_equal({ accepted: true, request_id: 'fixture-receipt' }, @draft.send_draft(access_token: 'fixture', draft_id: 'draft'))
    assert_equal '', @calls.last[:body]
    @response = Net::ReadTimeout.new
    assert_raises(Net::ReadTimeout) { @draft.send_draft(access_token: 'fixture', draft_id: 'draft') }
    assert_equal 2, @calls.length
    @response = { status: 503, body: '{}' }
    assert assert_raises(Api::Error) { @draft.send_draft(access_token: 'fixture', draft_id: 'draft') }.possibly_accepted?
  end

  def test_network_transport_rejects_token_forwarding_or_unapproved_hosts_before_network
    transport = Transport.new
    [UPLOAD, 'https://evil.example/v1.0/me', 'http://graph.microsoft.com/v1.0/me',
     'https://graph.microsoft.com/v1.0/users/another', 'https://login.microsoftonline.com/other/oauth2/v2.0/token'].each do |url|
      assert_raises(ArgumentError) { transport.call(method: :put, url: url, headers: { 'Authorization' => 'Bearer fixture' }) }
    end
  end

  def test_stream_limit_stops_large_response_and_http_retry_is_disabled
    response = Object.new
    response.define_singleton_method(:read_body) { |&block| block.call('abc'); block.call('def') }
    http = Object.new
    retry_count = nil
    http.define_singleton_method(:max_retries=) { |count| retry_count = count }
    http.define_singleton_method(:request) { |_request, &block| block.call(response) }
    start = ->(*_args, **_options, &block) { block.call(http) }
    Net::HTTP.stub(:start, start) do
      error = assert_raises(Api::Error) do
        Transport.new.call(method: :get, url: 'https://graph.microsoft.com/v1.0/me', headers: {}, max_bytes: 5)
      end
      assert_equal 413, error.status
    end
    assert_equal 0, retry_count
  end
end
