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
    %w[/super_admin/settings /login /auth/sign_in /auth/password /password/reset /health /api/v1/profile /apple /v3application].each do |path|
      _status, _headers, body = response(path: path)
      refute_includes(body.join, 'data-toybaco-post-config', path)
      refute_includes(body.join, 'toybaco-post-entry.js', path)
      refute_includes(body.join, 'toybaco-agent-seat.js', path)
    end

    existing = '<html><head><script data-toybaco-post-config></script></head><body></body></html>'
    _status, _headers, body = response(path: '/app', body: existing)
    assert_equal(1, body.join.scan('data-toybaco-post-config').length)
  end

  def test_root_dashboard_has_controls_before_spa_navigation_and_does_not_duplicate_them
    source = '<html lang="en"><head></head><body><noscript>This app works best with JavaScript enabled.</noscript></body></html>'
    %w[/ /app/login /app/password/reset /v3app/login].each do |path|
      _status, headers, body = response(path: path, body: source)
      html = body.join
      %w[data-toybaco-post-config toybaco-post-entry.js toybaco-agent-seat.js].each do |marker|
        assert_equal(1, html.scan(marker).length, path)
        assert_operator(html.index(marker), :<, html.index('<body>'))
      end
      assert_includes(html, '<html lang="ja">', path)
      assert_includes(html, 'このアプリを利用するにはJavaScriptを有効にしてください。', path)
      assert_equal(html.bytesize.to_s, headers['Content-Length'])
      _status, _headers, repeated = response(path: path, body: html)
      %w[data-toybaco-post-config toybaco-post-entry.js toybaco-agent-seat.js].each do |marker|
        assert_equal(1, repeated.join.scan(marker).length, path)
      end
    end
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

  # BaseBubble shares right-bubble across public blue/iris and private amber.
  # typography.bubble uses slate/alpha tokens rather than inheriting parent color.
  def test_public_rich_text_and_nested_code_keep_normal_text_contrast
    public_bubble = '.right-bubble:is(.bg-n-solid-blue, .bg-n-solid-iris)'
    prose = bubble_rule("#{public_bubble} .prose-bubble")
    navy = brand_css[/--toybaco-navy:\s*#([0-9a-f]{6});/i, 1].scan(/../).map { |v| v.to_i(16) }
    body = prose[/--slate-12:\s*([\d ]+);/, 1].to_s.split.map(&:to_f)
    secondary = prose[/--slate-11:\s*([\d ]+);/, 1].to_s.split.map(&:to_f)
    [body, secondary].each do |color|
      assert_equal(3, color.length)
      assert(color.all? { |v| v.between?(0, 255) })
      assert_operator(contrast(color, navy), :>=, 4.5)
    end
    surface = prose[/--alpha-3:\s*([\d., ]+);/, 1].to_s.split(',').map(&:to_f)
    assert_equal(4, surface.length, 'code/pre needs a surface scoped to the pale public text')
    assert(surface.take(3).all? { |v| v.between?(0, 255) } && surface[3].between?(0, 1))
    code_background = navy
    2.times do
      code_background = code_background.each_with_index.map { |v, i| surface[i] * surface[3] + v * (1 - surface[3]) }
      assert_operator(contrast(secondary, code_background), :>=, 4.5, 'inline and nested pre/code must be readable')
    end
    assert_match(/color:\s*#d6e4f2\s*!important;/, bubble_rule("#{public_bubble} .prose-bubble a"))
    assert_match(/--slate-11:\s*214 228 242;/, bubble_rule("#{public_bubble} > .text-xs"))
  end

  def test_private_memos_and_submitted_values_keep_their_own_theme_colors
    private_bubble = '.right-bubble.bg-n-solid-amber'
    [private_bubble, "#{private_bubble}:hover"].each do |selector|
      rule = bubble_rule(selector)
      assert_match(/background-color:\s*rgb\(var\(--solid-amber\)\)\s*!important;/, rule)
      assert_match(/color:\s*rgb\(var\(--amber-12\)\)\s*!important;/, rule)
    end
    assert_match(/color:\s*rgb\(var\(--amber-12\)\)\s*!important;/, bubble_rule("#{private_bubble} > .text-xs"))
    value = '.right-bubble:is(.bg-n-solid-blue, .bg-n-solid-iris)[data-bubble-name="text"] > .gap-3 > .bg-n-alpha-3'
    assert_match(/color:\s*rgb\(var\(--slate-12\)\)\s*!important;/, bubble_rule(value))
    refute_match(/\.right-bubble\s+\*\s*\{[^}]*color:/, brand_css, 'do not force white onto all children or form controls')
  end

  def test_dark_incoming_email_has_a_paper_surface_without_recoloring_sender_html
    selector = '.dark .left-bubble[data-bubble-name="email"] .letter-render'
    paper = bubble_rule(selector)
    background = paper[/background-color:\s*#([0-9a-f]{6});/i, 1].to_s.scan(/../).map { |v| v.to_i(16) }
    body = paper[/--slate-12:\s*([\d ]+);/, 1].to_s.split.map(&:to_f)
    quote = paper[/--slate-11:\s*([\d ]+);/, 1].to_s.split.map(&:to_f)
    assert_equal([255, 255, 255], background)
    assert_match(/color:\s*rgb\(var\(--slate-12\)\);/, paper)
    [body, quote, [34, 34, 34]].each do |color|
      assert_equal(3, color.length)
      assert_operator(contrast(color, background), :>=, 4.5, 'default prose, quotes and a dark sender signature need readable contrast')
    end
    refute_includes(paper, '!important', 'sender inline colors and backgrounds must retain their own cascade')
    refute_match(/^#{Regexp.escape(selector)}\s+[^\{]+\{/, brand_css, 'do not recolor descendants, including light text on an explicit dark sender background')
    assert_operator(contrast([255, 255, 255], [32, 36, 43]), :>=, 4.5, 'the unchanged explicit sender color pair stays readable')
  end

  def test_posting_contains_native_stacking_without_changing_dialogs_or_layout
    host = '[data-toybaco-post-host]:has(> [data-toybaco-post-entry-panel])'
    native = "#{host} > :has(.resizable-editor-wrapper)"
    native_rule = bubble_rule(native)
    assert_match(/isolation:\s*isolate;/, native_rule, 'nested resize handles must not escape the native layer')
    assert_match(/z-index:\s*0;/, native_rule, 'native roots must remain below the existing posting layer')
    refute_match(/(?:display|position|visibility|pointer-events)\s*:/, native_rule, 'keep native layout and interaction on return')
    refute_match(/^\[data-toybaco-post-host\]\s*\{/, brand_css, 'isolation must end when the posting panel closes')
    refute_match(/^#{Regexp.escape(host)}\s*\{/, brand_css, 'keep main dialogs above sidebar layers')
    refute_match(/^#{Regexp.escape(host)}\s*>\s*:not\(/, brand_css, 'do not lower other native dialogs and floating controls')
  end

  def test_embedded_workspace_hides_only_the_mounted_route_and_expanded_submenus
    route = bubble_rule('[data-toybaco-embedded-background="route"]')
    assert_match(/visibility:\s*hidden\s*!important;/, route)
    assert_includes(brand_css, '[data-toybaco-embedded-background="route"] * {',
                    'explicitly visible settings headers must not escape the hidden route')
    refute_match(/(?:display|position|height|overflow)\s*:/, route, 'retain input and scroll geometry')
    assert_match(/display:\s*none\s*!important;/, bubble_rule('[data-toybaco-embedded-background="nav"]'))
    assert_includes(brand_css,
                    '[data-toybaco-primary-nav]:has(> [data-toybaco-embedded-background="nav"]) > ' \
                    '[data-toybaco-nav-link] .i-lucide-chevron-up', 'temporarily collapsed menus must not show an expanded arrow')

    dashboard = File.read(File.expand_path('../overlay/app/app/javascript/dashboard/routes/dashboard/Dashboard.vue', __dir__))
    wrapper = dashboard[/<div data-toybaco-native-route style="display: contents">.*?<\/div>/m]
    refute_nil(wrapper)
    assert_equal('<div data-toybaco-native-route style="display: contents"> <router-view /> </div>', wrapper.gsub(/\s+/, ' '))
    assert_equal(1, dashboard.scan('data-toybaco-native-route').length)
    %w[CopilotLauncher MobileSidebarLauncher CopilotContainer FloatingCallWidget CommandBar AddAccountModal WootKeyShortcutModal].each do |component|
      assert_includes(dashboard.split(wrapper, 2).last, "<#{component}", 'shared controls must stay outside the inert native route')
    end
    refute_match(/v-(?:if|show)|:key/, wrapper, 'opening an iframe must not remount the native router view')
  end

  private

  def brand_css
    File.read(File.expand_path('../overlay/app/public/toybaco-brand.css', __dir__))
  end

  def bubble_rule(selector)
    rule = brand_css[/^#{Regexp.escape(selector)}(?:,\s*[^{}]+)?\s*\{([^}]+)\}/, 1]
    refute_nil(rule, "missing scoped bubble rule: #{selector}")
    rule
  end

  def contrast(first, second)
    luminance = lambda do |rgb|
      channels = rgb.map { |v| v / 255.0 }.map { |v| v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055)**2.4 }
      channels.zip([0.2126, 0.7152, 0.0722]).sum { |v, weight| v * weight }
    end
    values = [luminance.call(first), luminance.call(second)].sort
    (values.last + 0.05) / (values.first + 0.05)
  end
end
