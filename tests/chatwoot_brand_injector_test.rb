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

  def test_command_palette_preserves_localized_keyboard_help_in_public_footer_slot
    source = File.read(File.expand_path('../overlay/app/app/javascript/dashboard/routes/dashboard/commands/commandbar.vue', __dir__))
    assert_includes(source, "const { t, tm } = useI18n();", 'keep existing global command translations')
    assert_includes(source, "const { t: footerT } = useI18n({")
    assert_includes(source, "useScope: 'local'")
    footer = source[/<div slot="footer" class="toybaco-command-footer">.*?<\/div>/m]
    refute_nil(footer, 'public slot replaces the dependency English fallback without hiding help')
    assert_equal(4, footer.scan('<kbd>').length)
    %w[SELECT NAVIGATE CLOSE PARENT].each { |key| assert_includes(footer, "footerT('#{key}')") }
    %w[選択 項目を移動 閉じる 一つ上へ戻る].each { |text| assert_includes(source, "'#{text}'") }
    %w[:placeholder= @change= @selected= @closed=].each { |binding| assert_includes(source, binding) }
    assert_includes(source, 'flex-wrap: wrap;')
    refute_match(/\.toybaco-command-footer[^}]*display:\s*none/m, source)
  end

  # S0-2(2026-10-06): トイバコ独自の画面は --toybaco-* トークンだけで色を書く。SPA の中は .dark に従う。
  # 単独画面は <html data-toybaco-theme="system"> で OS の設定に従い、ご契約内容の iframe で開く画面は親のテーマ
  # (dark / light)を受け取る。どちらのダークも .dark と同じ値にする。ブランドの CSS は画面自身で読み込む
  # (エラー応答には差し込みが無い)。
  STANDALONE_PAGES = %w[
    toybaco/billing/show toybaco/checkout/confirm toybaco/checkout/error toybaco/growth/held toybaco/growth/inbox_release
    toybaco/growth/posting_release toybaco/growth/retention toybaco/growth/purchase toybaco/growth/packs toybaco/growth/trial
    toybaco/connections/handoff_owner toybaco/connections/handoff_portal toybaco/managed_auto/show
    toybaco/free_registrations/show toybaco/free_registrations/verify_email layouts/toybaco_mfa_enrollment
  ].map { |name| "app/views/#{name}.html.erb" }.freeze
  FRAMED_PAGES = %w[billing/show growth/held growth/inbox_release growth/posting_release growth/retention]
                 .map { |name| "app/views/toybaco/#{name}.html.erb" }.freeze
  TOKEN_SHEETS = %w[
    public/brand-assets/toybaco-pointer-guide.css public/brand-assets/toybaco-managed-auto.css
    public/brand-assets/toybaco-growth-purchase.css public/brand-assets/toybaco-growth-trial.css
    public/brand-assets/toybaco-free-signup.css public/brand-assets/toybaco-connection-handoff.css
    public/brand-assets/toybaco-help.css
    app/javascript/dashboard/routes/dashboard/onboarding/ToybacoStart.vue
    app/javascript/dashboard/components/widgets/ToybacoGrowthGuide.vue
    app/javascript/dashboard/components/widgets/ToybacoTour.vue
  ].freeze
  COLOR_LITERAL = /#\h{3,8}\b|rgba?\(|:\s*white\b|color-scheme:\s*light/i
  BRAND_ASSET_URL = %r{/(brand-assets/[\w.-]+\.(?:css|js|mjs)|toybaco-brand\.css|toybaco-superadmin\.css)(?:\?v=(\h{64}))?}
  DARK_BLOCK = /^\.dark,\n\[data-toybaco-theme="dark"\] \{([^}]*)\}/
  LIGHT_BLOCK = /^:root \{([^}]*)\}/

  def test_dark_tokens_are_the_same_for_the_dashboard_the_parent_theme_and_the_os_setting
    css = brand_css
    refute_match(/^\.dark \{/, css, 'every dashboard dark block also answers data-toybaco-theme="dark"')
    assert_equal(2, css.scan(DARK_BLOCK).length)
    assert_includes(css, %([data-toybaco-theme="dark"] {\n  color-scheme: dark;\n}))
    system = css[/@media \(prefers-color-scheme: dark\) \{\s*\[data-toybaco-theme="system"\] \{([^}]*)\}/, 1]
    refute_nil(system, 'the OS dark block exists and is scoped to standalone pages')
    assert_match(/color-scheme: dark;/, system)
    assert_equal(theme_tokens(DARK_BLOCK), toybaco_tokens(system))
    refute_match(/@media \(prefers-color-scheme: dark\) \{\s*:root/, css, 'the SPA keeps its own light/dark choice')
    light = theme_tokens(LIGHT_BLOCK)
    theme_tokens(DARK_BLOCK).each_key { |name| assert(light[name], "#{name} has a light value") }
  end

  # 未ログインの画面は html に .dark が付く。:root で暖色にした --background-color がダークでも残ると、認証画面の main
  # (背景はこの値)だけ明るいまま、見出し(ダークでは blue-12)とタグライン(blue-11)が明るくなって読めない(2026-10-07)。
  def test_auth_page_background_is_dark_under_the_dark_theme
    assert_match(/background-color:\s*rgb\(var\(--background-color\)\)\s*!important;/, bubble_rule('main[class*="bg-n-brand/5"]'))
    dark = brand_css.scan(DARK_BLOCK).flatten.join("\n")
    rgb = ->(name) { dark[/#{Regexp.escape(name)}:\s*([\d ]+);/, 1].to_s.split.map(&:to_i) }
    background = rgb.call('--background-color')
    assert_equal([28, 29, 32], background, 'the dark theme sets its own background (the upstream dark value)')
    assert_operator(contrast(rgb.call('--blue-12'), background), :>=, 4.5, 'the heading stays readable')
    assert_operator(contrast(rgb.call('--blue-11'), background), :>=, 4.5, 'and the tagline')
  end

  # Grok 指摘(2026-10-06): ダークの主ボタンの面が周りに沈み、区切り線とホバーが見分けにくかった。
  def test_buttons_lines_and_hover_keep_the_reviewed_contrast_in_both_themes
    [theme_tokens(LIGHT_BLOCK), theme_tokens(DARK_BLOCK)].each do |tokens|
      rgb = ->(name) { tokens.fetch(name).delete('#').scan(/../).map { |v| v.to_i(16) } }
      %w[--toybaco-button --toybaco-button-hover].each do |face|
        assert_operator(contrast(rgb.call('--toybaco-on-button'), rgb.call(face)), :>=, 4.5, "#{face} keeps its text readable")
        %w[--toybaco-card --toybaco-surface --toybaco-offwhite].each do |ground|
          assert_operator(contrast(rgb.call(face), rgb.call(ground)), :>=, 3, "#{face} stands out on #{ground}")
        end
      end
      assert_operator(contrast(rgb.call('--toybaco-button'), rgb.call('--toybaco-button-hover')), :>=, 1.1, 'primary hover differs from rest')
      assert_operator(contrast(rgb.call('--toybaco-wash-strong'), rgb.call('--toybaco-wash')), :>=, 1.15, 'secondary hover differs from rest')
      assert_operator(contrast(rgb.call('--toybaco-heading'), rgb.call('--toybaco-wash-strong')), :>=, 4.5)
    end
    dark = theme_tokens(DARK_BLOCK).transform_values { |value| value.delete('#').scan(/../).map { |v| v.to_i(16) } }
    %w[--toybaco-card --toybaco-surface].each do |ground|
      assert_operator(contrast(dark.fetch('--toybaco-hairline'), dark.fetch(ground)), :>=, 1.5, "dark cards are edged by the line on #{ground}")
    end
  end

  def test_standalone_pages_load_the_brand_and_colour_their_own_styles_with_tokens
    STANDALONE_PAGES.each do |path|
      page = overlay_file(path)
      theme = FRAMED_PAGES.include?(path) ? '<%= Toybaco::BrandInjector.page_theme(@toybaco_theme) %>' : 'system'
      assert_includes(page, %(<html lang="ja" data-toybaco-theme="#{theme}">), path)
      assert_includes(page, %(<link rel="stylesheet" href="<%= Toybaco::BrandInjector.asset_path('toybaco-brand.css') %>">), path)
      styles = page.scan(%r{<style[^>]*>(.*?)</style>}m).flatten.join("\n")
      refute_match(COLOR_LITERAL, styles, "#{path} colours its own styles with tokens")
    end
    # 同じ iframe の中でたどる導線はテーマを引き継ぐ(target="_top" で SPA の外へ出る導線は OS の設定に従う)。
    FRAMED_PAGES.each do |path|
      links = overlay_file(path).scan(/<a\b(?:<%.*?%>|[^<>])*>/m).grep(%r{href="/toybaco/}).grep_v(/target="_top"/)
      refute_empty(links, path)
      links.each { |link| assert_includes(link, '<%= Toybaco::BrandInjector.theme_query(@toybaco_theme) %>', "#{path}: #{link}") }
    end
    # ヘルプは静的な 200 応答なので、ブランドの CSS は差し込み(digest 付き)に任せ、画面では読み込まない。
    help = overlay_file('public/toybaco-help.html')
    assert_includes(help, '<html lang="ja" data-toybaco-theme="system">')
    refute_includes(help, 'toybaco-brand.css')
    TOKEN_SHEETS.each do |path|
      source = overlay_file(path)
      styles = path.end_with?('.vue') ? source[source.index('<style')..] : source
      refute_match(COLOR_LITERAL, styles, "#{path} colours with tokens")
    end
  end

  def test_standalone_page_helpers_version_assets_and_accept_only_the_dashboard_themes
    script = File.join(overlay_root, 'public/brand-assets/toybaco-plan-change.js')
    assert_equal("/brand-assets/toybaco-plan-change.js?v=#{Digest::SHA256.file(script).hexdigest}",
                 Toybaco::BrandInjector.asset_path('brand-assets/toybaco-plan-change.js'))
    assert_equal("/toybaco-brand.css?v=#{Toybaco::BrandInjector::BRAND_ASSET_DIGEST}", Toybaco::BrandInjector.asset_path('toybaco-brand.css'))
    ['brand-assets/missing.css', '../config/routes.rb', '/etc/hosts', 'brand-assets'].each do |relative|
      assert_raises(ArgumentError, relative) { Toybaco::BrandInjector.asset_path(relative) }
    end
    { 'dark' => 'dark', 'light' => 'light', 'system' => 'system', 'Dark' => 'system', 'sepia' => 'system', '' => 'system',
      nil => 'system', ['dark'] => 'system', { 'dark' => '1' } => 'system' }.each do |given, expected|
      assert_equal(expected, Toybaco::BrandInjector.page_theme(given), given.inspect)
      assert_equal(expected == 'system' ? '' : "&theme=#{expected}", Toybaco::BrandInjector.theme_query(given), given.inspect)
    end
  end

  # 再現可能 build はファイルの時刻を固定するので、版の無い URL は再検証しても古い内容のまま残る。ブランドの CSS・JS は、
  # 単独画面(ERB)・SPA の部品・静的ページ・差し込みのどこからも、実ファイルの内容の digest を付けた URL で読む。
  def test_every_brand_stylesheet_and_script_url_carries_the_digest_of_the_deployed_file
    used = []
    Dir[File.join(overlay_root, 'app/views/**/*.erb')].each do |file|
      source = File.read(file)
      refute_match(BRAND_ASSET_URL, source, "#{file} builds brand asset URLs with BrandInjector.asset_path")
      used.concat(source.scan(/BrandInjector\.asset_path\('([^']+)'\)/).flatten)
    end
    assert_includes(used, 'toybaco-brand.css')
    assert_includes(used, 'brand-assets/toybaco-plan-change.js')
    used.uniq.each do |relative|
      file = File.join(overlay_root, 'public', relative)
      assert(File.file?(file), relative)
      assert_equal("/#{relative}?v=#{Digest::SHA256.file(file).hexdigest}", Toybaco::BrandInjector.asset_path(relative))
    end

    sources = Dir[File.join(overlay_root, '{app/javascript,public}/**/*.{vue,js,mjs,html}')].to_h { |file| [file, File.read(file)] }
    %w[/app/accounts/1/dashboard /super_admin/settings].each { |path| sources[path] = response(path: path)[2].join }
    found = []
    sources.each do |name, source|
      source.scan(BRAND_ASSET_URL) do |relative, digest|
        found << relative
        file = File.join(overlay_root, 'public', relative)
        assert(File.file?(file), "#{name}: #{relative}")
        assert_equal(Digest::SHA256.file(file).hexdigest, digest, "#{name}: #{relative} needs ?v=<sha256 of the deployed file>")
      end
    end
    %w[toybaco-brand.css toybaco-superadmin.css brand-assets/toybaco-post-entry.js brand-assets/toybaco-agent-seat.js
       brand-assets/toybaco-pointer-guide.mjs brand-assets/toybaco-pointer-guide.css brand-assets/toybaco-help.css].each do |relative|
      assert_includes(found, relative)
    end
  end

  private

  def brand_css
    File.read(File.expand_path('../overlay/app/public/toybaco-brand.css', __dir__))
  end

  def overlay_root
    File.expand_path('../overlay/app', __dir__)
  end

  def overlay_file(path)
    File.read(File.join(overlay_root, path))
  end

  def toybaco_tokens(block)
    block.scan(/(--toybaco-[a-z-]+):\s*([^;]+);/).to_h { |name, value| [name, value.strip] }
  end

  def theme_tokens(pattern)
    brand_css.scan(pattern).flatten.map { |block| toybaco_tokens(block) }.reduce({}, :merge)
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

require 'minitest/mock'
require_relative '../overlay/app/lib/toybaco/source_offer'

class ChatwootSourceOfferTest < Minitest::Test
  def with_source_offer(revision)
    path = '/toybaco-source-offer-test/TOYBACO_PUBLIC_REVISION'
    file_exists = lambda do |requested|
      raise "unexpected revision path: #{requested}" unless requested == path

      !revision.nil?
    end
    read_revision = lambda do |requested|
      raise "unexpected revision read: #{requested}" unless requested == path && !revision.nil?

      revision
    end
    app = ->(_env) { [418, {}, ['delegated']] }
    File.stub(:file?, file_exists) do
      File.stub(:read, read_revision) do
        yield Toybaco::SourceOffer.new(app, revision_path: path)
      end
    end
  end

  def request(method = 'GET', path = '/toybaco/source')
    { 'REQUEST_METHOD' => method, 'PATH_INFO' => path, 'QUERY_STRING' => 'revision=main&url=https://example.invalid' }
  end

  def test_exact_build_revision_is_the_only_redirect_target
    revision = '0123456789abcdef' * 2 + '01234567'
    with_source_offer("#{revision}\n") do |offer|
      status, headers, body = offer.call(request)
      assert_equal(302, status)
      assert_equal("https://github.com/Cyber-relations/chatwoot/tree/#{revision}", headers['location'])
      assert_equal('no-store', headers['cache-control'])
      assert_empty(body)
      assert_equal([status, headers, body], offer.call(request('HEAD')))
    end
  end

  def test_missing_or_invalid_revision_never_claims_main_as_deployed
    [nil, '', 'main', 'A' * 40, 'a' * 39, 'a' * 41, 'https://example.invalid'].each do |revision|
      with_source_offer(revision) do |offer|
        status, headers, body = offer.call(request)
        assert_equal(503, status, revision.inspect)
        refute(headers.key?('location'))
        assert_includes(body.join, '対応ソースを確認できません')
        assert_empty(offer.call(request('HEAD'))[2])
      end
    end
  end

  def test_other_paths_and_methods_keep_existing_app_behavior
    with_source_offer('a' * 40) do |offer|
      [['POST', '/toybaco/source'], ['GET', '/toybaco/source/'], ['GET', '/app']].each do |method, path|
        assert_equal([418, {}, ['delegated']], offer.call(request(method, path)))
      end
    end
  end
end
