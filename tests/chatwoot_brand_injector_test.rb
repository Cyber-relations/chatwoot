# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../overlay/app/lib/toybaco/brand_injector'

class ChatwootBrandInjectorTest < Minitest::Test
  def response(path:, body: '<html><head></head><body>dashboard</body></html>', headers: nil, **options)
    response_headers = headers || { 'Content-Type' => 'text/html', 'Transfer-Encoding' => 'chunked' }
    app = lambda { |_env| [200, response_headers, [body]] }
    Toybaco::BrandInjector.new(app, **options).call('PATH_INFO' => path, 'REQUEST_METHOD' => 'GET')
  end

  def test_dashboard_automatically_gets_validated_post_entry_without_installation_config
    _status, headers, body = response(
      path: '/app/accounts/1/inbox',
      postiz_origin: 'https://post.staging.toybaco.jp/'
    )
    html = body.join

    assert_includes(html, 'data-toybaco-post-config')
    assert_includes(html, '"postUrl":"https://post.staging.toybaco.jp"')
    assert_includes(
      html,
      %(<script src="/brand-assets/toybaco-post-entry.js?v=#{Toybaco::BrandInjector::POST_ENTRY_ASSET_DIGEST}" defer></script>)
    )
    assert_includes(
      html,
      %(<script src="/brand-assets/toybaco-agent-seat.js?v=#{Toybaco::BrandInjector::AGENT_SEAT_ASSET_DIGEST}" defer></script>)
    )
    assert_match(%r{/brand-assets/toybaco-post-entry\.js\?v=[0-9a-f]{64}}, html)
    assert_operator(html.index('data-toybaco-post-config'), :<, html.index('<body>'))
    assert_equal(html.bytesize.to_s, headers['Content-Length'])
    refute(headers.key?('Transfer-Encoding'))
  end

  def test_post_entry_is_limited_to_dashboard_routes_and_injected_once
    _status, _headers, body = response(path: '/super_admin/settings')
    refute_includes(body.join, 'data-toybaco-post-config')

    existing = '<html><head><script data-toybaco-post-config></script></head><body></body></html>'
    _status, _headers, body = response(path: '/app', body: existing)
    assert_equal(1, body.join.scan('data-toybaco-post-config').length)
  end

  def test_brand_stylesheet_url_uses_the_deployed_content_digest
    digest = Digest::SHA256.file(File.expand_path('../overlay/app/public/toybaco-brand.css', __dir__)).hexdigest
    _status, _headers, body = response(path: '/app/accounts/1/dashboard')

    assert_includes(body.join, %(<link rel="stylesheet" href="/toybaco-brand.css?v=#{digest}">))
    refute_includes(body.join, 'href="/toybaco-brand.css"')
  end

  def test_existing_versioned_brand_stylesheet_is_not_duplicated
    digest = Digest::SHA256.file(File.expand_path('../overlay/app/public/toybaco-brand.css', __dir__)).hexdigest
    source = %(<html><head><link rel="stylesheet" href="/toybaco-brand.css?v=#{digest}"></head><body></body></html>)
    _status, _headers, body = response(path: '/app/accounts/1/dashboard', body: source)

    assert_equal(1, body.join.scan('toybaco-brand.css').length)
    assert_includes(body.join, %(href="/toybaco-brand.css?v=#{digest}"))
  end

  def test_brand_stylesheet_keeps_short_cache_without_relying_on_file_mtime
    _status, headers, body = response(
      path: '/toybaco-brand.css', body: 'body { color: black; }',
      headers: { 'Content-Type' => 'text/css', 'Last-Modified' => 'Sat, 01 Jan 2000 00:00:00 GMT' }
    )

    assert_equal('public, max-age=300, must-revalidate', headers['Cache-Control'])
    assert_equal('Sat, 01 Jan 2000 00:00:00 GMT', headers['Last-Modified'])
    assert_equal('body { color: black; }', body.join)
  end

  def test_dashboard_document_language_and_noscript_are_japanese
    source = <<~HTML
      <html lang="en"><head></head><body>
      <noscript id="noscript">This app works best with JavaScript enabled.</noscript>
      </body></html>
    HTML
    _status, _headers, body = response(path: '/app/login', body: source)
    html = body.join

    assert_includes(html, '<html lang="ja">')
    assert_includes(html, 'このアプリを利用するにはJavaScriptを有効にしてください。')
    refute_includes(html, 'This app works best with JavaScript enabled.')
  end

  def test_invalid_post_origin_fails_closed_before_serving_dashboard
    error = assert_raises(ArgumentError) do
      response(path: '/app', postiz_origin: 'https://evil.example/path')
    end
    refute_includes(error.message, 'evil.example')
  end

  def test_invalid_billing_url_is_omitted_without_disabling_post_entry
    _status, _headers, body = response(
      path: '/v3app/accounts/1',
      postiz_origin: 'http://post.toybaco.localhost:4007',
      billing_url: 'https://evil.example/customer'
    )
    html = body.join

    assert_includes(html, '"postUrl":"http://post.toybaco.localhost:4007"')
    refute_includes(html, '"billingUrl":')
    assert_includes(html, 'toybaco-post-entry.js')
  end
end
