# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../overlay/app/lib/toybaco/dashboard_frame_policy'

class ChatwootFramePolicyTest < Minitest::Test
  def response(path, headers: {}, postiz_origin: 'https://post.toybaco.jp')
    app = lambda { |_env| [200, headers, ['ok']] }
    Toybaco::DashboardFramePolicy.new(app, postiz_origin: postiz_origin).call('PATH_INFO' => path)
  end

  def test_dashboard_gets_exact_parent_and_postiz_child_policy
    _status, headers, = response('/app/accounts/1/inbox')

    assert_equal(
      "frame-ancestors 'self'; frame-src 'self' https://post.toybaco.jp",
      headers['Content-Security-Policy']
    )
    assert_equal('SAMEORIGIN', headers['X-Frame-Options'])
  end

  def test_existing_policy_is_preserved_and_unsafe_frame_directives_are_replaced
    original = {
      'Content-Security-Policy' =>
        "default-src 'self'; frame-src https://evil-frame.example; frame-ancestors https://evil.example; img-src https:"
    }
    _status, headers, = response('/app/login', headers: original)
    policy = headers.fetch('Content-Security-Policy')

    assert_includes(policy, "default-src 'self'")
    assert_includes(policy, 'img-src https:')
    assert_equal(1, policy.scan(/(?:^|; )frame-ancestors\b/).length)
    assert_equal(1, policy.scan(/(?:^|; )frame-src\b/).length)
    assert_includes(policy, "frame-ancestors 'self'")
    assert_includes(policy, "frame-src 'self' https://post.toybaco.jp")
    refute_includes(policy, 'evil.example')
    refute_includes(policy, 'evil-frame.example')
    assert_equal(
      "default-src 'self'; frame-src https://evil-frame.example; frame-ancestors https://evil.example; img-src https:",
      original['Content-Security-Policy']
    )
  end

  def test_all_protected_prefixes_and_root_are_covered
    ['/', '/app', '/v3app/', '/super_admin/users', '/installation/onboarding', '/toybaco/oidc/authorize'].each do |path|
      _status, headers, = response(path)
      assert(headers.key?('Content-Security-Policy'), path)
    end
  end

  def test_widget_public_and_api_routes_are_untouched
    ['/widget', '/widget?website_token=x', '/packs/js/sdk.js', '/api/v1/accounts', '/public/api/v1/inboxes'].each do |path|
      original = { 'Content-Security-Policy' => "default-src 'none'" }
      _status, headers, = response(path, headers: original)
      assert_same(original, headers, path)
      assert_equal("default-src 'none'", headers['Content-Security-Policy'], path)
    end
  end

  def test_similar_prefixes_do_not_accidentally_match
    ['/application', '/app-malicious', '/toybaco.example'].each do |path|
      _status, headers, = response(path)
      refute(headers.key?('Content-Security-Policy'), path)
    end
  end

end
