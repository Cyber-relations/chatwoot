# frozen_string_literal: true

require 'minitest/autorun'
require 'digest'
require_relative '../overlay/app/lib/toybaco/checkout/catalog'

# ご契約画面に出すプラン名は LP のライト / スタンダード / プロだけ。
# Chatwoot 在庫名(ビジネス / スターター / ハッカー / エンタープライズ)は出さない。
class ChatwootBillingPlanNamesTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  CATALOG = Toybaco::Checkout::Catalog
  EXPECTED = {
    'light' => 'ライト',
    'standard' => 'スタンダード',
    'pro' => 'プロ'
  }.freeze
  STOCK_CHATWOOT_NAMES = %w[
    ビジネス スターター ハッカー エンタープライズ
    Business Starter Hacker Enterprise Premium
  ].freeze

  def test_customer_plan_names_match_lp_self_serve_three
    assert_equal %w[light standard pro], CATALOG::PLANS
    assert_equal EXPECTED, CATALOG::CUSTOMER_PLAN_NAMES
    assert_equal EXPECTED.values, CATALOG::CUSTOMER_PLAN_NAMES.values
    assert_equal 3, CATALOG::CUSTOMER_PLAN_NAMES.length
    refute CATALOG::CUSTOMER_PLAN_NAMES.key?('premium')
    refute CATALOG::CUSTOMER_PLAN_NAMES.key?('business')
  end

  def test_billing_info_maps_self_serve_keys_to_lp_names
    EXPECTED.each do |key, name|
      info = CATALOG.billing_info(key)
      assert_equal name, info[:name], key
      assert_equal "#{name} プラン", "#{info[:name]} プラン"
    end
  end

  def test_legacy_starter_is_light_rename_not_a_fourth_plan
    info = CATALOG.billing_info('starter')
    assert_equal 'ライト', info[:name]
    assert_equal CATALOG.billing_info('light'), info
    assert_equal({ 'starter' => 'light' }, CATALOG::PLAN_KEY_ALIASES)
  end

  def test_stock_chatwoot_plan_keys_have_no_customer_label
    %w[business enterprise hacker premium community].each do |key|
      assert_nil CATALOG.billing_info(key), key
    end
  end

  def test_customer_visible_names_are_not_chatwoot_stock
    names = CATALOG::CUSTOMER_PLAN_NAMES.values
    STOCK_CHATWOOT_NAMES.each do |stock|
      refute_includes names, stock
    end
    blob = names.join
    refute_includes blob, 'ビジネス'
    refute_includes blob, 'ハッカー'
    refute_includes blob, 'エンタープライズ'
    refute_includes blob, 'スターター'
  end

  def test_billing_controller_uses_catalog_and_drops_stock_plan_info
    controller = File.read(File.join(ROOT, 'overlay/app/app/controllers/toybaco/billing_controller.rb'))

    assert_includes controller, 'Toybaco::Entitlements.contract_for(@account)'
    assert_includes controller, 'Toybaco::BillingSubscription.summarize'
    refute_includes controller, 'Catalog.billing_info(@plan_key)'
    assert_includes controller, 'return unless @subscription_id'
    refute_includes controller, 'PLAN_INFO'
    refute_includes controller, 'ビジネス'
    refute_includes controller, 'スターター'
    refute_includes controller, 'ハッカー'
    refute_includes controller, 'エンタープライズ'
    refute_match(/sk_live|rk_live|whsec_/, controller)
  end

  def test_billing_view_renders_catalog_name_not_stock_chatwoot_plans
    view = File.read(File.join(ROOT, 'overlay/app/app/views/toybaco/billing/show.html.erb'))

    assert_includes view, 'ご契約内容'
    assert_includes view, '@plan[:name] %> プラン'
    refute_includes view, 'ビジネス プラン'
    refute_includes view, 'ビジネスプラン'
    refute_includes view, 'スターター'
    refute_includes view, 'ハッカー'
    refute_includes view, 'エンタープライズ'
    refute_includes view, 'Hacker'
    refute_includes view, 'Enterprise'
    refute_match(/Captain|キャプテン/, view)
  end

  def test_app_billing_pages_use_the_lp_terms
    view = File.read(File.join(ROOT, 'overlay/app/app/views/toybaco/billing/show.html.erb'))
    purchase = File.read(File.join(ROOT, 'overlay/app/app/views/toybaco/growth/purchase.html.erb'))
    packs = File.read(File.join(ROOT, 'overlay/app/app/views/toybaco/growth/packs.html.erb'))
    retention = File.read(File.join(ROOT, 'overlay/app/app/views/toybaco/growth/retention.html.erb'))
    # The free catalog name stays in stored contracts; customers see the LP name.
    assert_includes view, '<% if growth_free %>無料プラン<% else %><%= @plan[:name] %> プラン<% end %>'
    assert_includes view, "growth ? 'AIアシスタント（返信・投稿で共通）'"
    assert_includes retention, "@state.fetch('target') == 'free' ? '無料プラン' : @state.fetch('target_name')"
    assert_includes purchase, '<small> / 月・税別</small>'
    assert_includes purchase, '<li>AIアシスタント 月'
    assert_includes packs, '円（税別）'
    [view, purchase, packs].each do |page|
      refute_match(/税抜|業務AI|右下のチャット|チャットでお知らせ/, page)
    end
    assert_includes view, '<a href="https://toybaco.jp/contact/" target="_blank" rel="noopener">お問い合わせフォーム</a>でも受け付けています'
    # 年払いでも請求は年 1 回。毎月あらたに数えるのは AI の回数で、自動応答は含むプランだけ。
    assert_includes purchase, '<p class="note">AIの回数は、返信と投稿で共通です。年払いでも、回数は毎月あらたに数えます。' \
                              '自動応答（スタンダード以上）は、設定したあとで始まります。</p>'
    refute_includes purchase, '年払いでも毎月更新します'
    assert_includes packs, '無料プラン／ライトへ変更後も'
    refute_includes packs, 'Free／Light'
    assert_includes view, '解約後に残す受信箱・投稿先を選べます。'
    assert_includes retention, "'inboxes' => '受信箱'"
    managed = File.read(File.join(ROOT, 'overlay/app/app/views/toybaco/managed_auto/show.html.erb'))
    assert_includes managed, '/dashboard">店舗の画面へ戻る</a>'
    views = Dir[File.join(ROOT, 'overlay/app/app/views/toybaco/**/*.erb')].map { |path| File.read(path) }.join
    refute_includes views, '受信ボックス'
  end

  def test_assignment_upsell_honors_brand_policy_and_preserves_assignment_behavior
    view = File.read(File.join(
                       ROOT,
                       'overlay/app/app/javascript/dashboard/routes/dashboard/settings/inbox/settingsPage/CollaboratorsPage.vue'
                     ))
    policy_import = "import { usePolicy } from 'dashboard/composables/usePolicy';\n"
    policy_setup = "const { shouldShowPaywall } = usePolicy();\n"
    old_prompt = <<~VUE
                      <div class="w-full h-px bg-n-weak my-4" />

                      <!-- Upgrade prompt when advanced_assignment is not enabled -->
                      <div v-if="!hasAdvancedAssignment">
    VUE
    new_prompt = <<~VUE
                      <!-- Upgrade prompt follows the existing custom-brand paywall policy. -->
                      <div
                        v-if="!hasAdvancedAssignment && shouldShowPaywall('advanced_assignment')"
                      >
                        <div class="w-full h-px bg-n-weak my-4" />
    VUE
    old_prompt = old_prompt.lines.map { |line| line == "\n" ? line : "                  #{line}" }.join
    new_prompt = new_prompt.lines.map { |line| "                  #{line}" }.join
    # Only the marketing branch changes; all assignment handlers and feature
    # checks must stay identical to the pinned upstream component.
    assert_equal 1, view.scan(policy_import).length
    assert_equal 1, view.scan(policy_setup).length
    assert_equal 1, view.scan(new_prompt).length
    restored = view.sub(policy_import, '').sub(policy_setup, '').sub(new_prompt, old_prompt)
    assert_equal '95aed927cda69216f3233a1894daaf052fa6fc9de63ed1ed288ca122566302ea', Digest::SHA256.hexdigest(restored)
  end
end
