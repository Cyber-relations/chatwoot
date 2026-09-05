# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../overlay/app/lib/toybaco/agent_seat_limit'

# ライトの担当者は LP どおり 3 名まで。課金・解約・OIDC は触らない。
class ChatwootAgentSeatLimitTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  LIMIT = Toybaco::AgentSeatLimit
  LP_TITLE = '利用は3名まで'
  LP_BODY = '何人で使っても、店舗ごとの定額のままです(ライトのみ3名まで)。'

  Users = Struct.new(:count)
  Account = Struct.new(:internal_attributes, :account_users)

  def account(plan, count)
    Account.new({ 'toybaco_plan' => plan }, Users.new(count))
  end

  def test_limit_is_read_from_contract_and_copy_is_japanese
    payload = LIMIT.payload(account('light', 2))
    assert_equal 3, payload['limit']
    assert_equal LP_TITLE, payload['title']
    assert_includes payload['message'], '現在2名'
    refute_includes payload['message'], 'Chatwoot'
  end

  def test_light_and_legacy_starter_cap_at_three
    %w[light starter].each do |plan|
      assert LIMIT.capped?(account(plan, 1)), plan
      assert_equal 3, LIMIT.limit_for(account(plan, 1))
      refute LIMIT.at_limit?(account(plan, 2)), plan
      assert LIMIT.at_limit?(account(plan, 3)), plan
      assert LIMIT.at_limit?(account(plan, 4)), plan
    end
  end

  def test_standard_and_pro_are_not_capped
    %w[standard pro premium business].each do |plan|
      refute LIMIT.capped?(account(plan, 10)), plan
      assert_nil LIMIT.limit_for(account(plan, 10)), plan
      refute LIMIT.at_limit?(account(plan, 10)), plan
    end
    refute LIMIT.capped?(account(nil, 10))
    refute LIMIT.capped?(account('', 10))
  end

  def test_payload_exposes_lp_copy_without_vendor_names
    payload = LIMIT.payload(account('light', 3))

    assert_equal true, payload['capped']
    assert_equal 3, payload['limit']
    assert_equal 3, payload['count']
    assert_equal true, payload['at_limit']
    assert_equal LP_TITLE, payload['title']
    assert_includes payload['message'], '現在3名'
    blob = payload.to_s
    refute_match(/Chatwoot|Captain|アップグレード/, blob)
  end

  def test_usage_limits_override_only_agents_on_light
    klass = Class.new do
      def initialize(plan, limits)
        @plan = plan
        @limits = limits
      end

      def internal_attributes
        { 'toybaco_plan' => @plan }
      end

      def usage_limits
        @limits
      end
    end
    klass.prepend(LIMIT::AccountUsageLimits)

    light = klass.new('light', { agents: 100_000, inboxes: 100_000 })
    assert_equal({ agents: 3, inboxes: 100_000 }, light.usage_limits)

    starter = klass.new('starter', { agents: 100_000, inboxes: 50 })
    assert_equal({ agents: 3, inboxes: 50 }, starter.usage_limits)

    standard = klass.new('standard', { agents: 100_000, inboxes: 100_000 })
    assert_equal({ agents: 100_000, inboxes: 100_000 }, standard.usage_limits)
  end

  def test_controller_and_initializer_do_not_rebuild_billing_or_oidc
    controller = File.read(File.join(ROOT, 'overlay/app/app/controllers/toybaco/agent_seat_limit_controller.rb'))
    initializer = File.read(File.join(ROOT, 'overlay/app/config/initializers/toybaco_agent_seat_limit.rb'))
    oidc = File.read(File.join(ROOT, 'overlay/app/config/initializers/toybaco_oidc.rb'))
    billing = File.read(File.join(ROOT, 'overlay/app/app/controllers/toybaco/billing_controller.rb'))

    assert_includes controller, 'Toybaco::AgentSeatLimit.payload(@account)'
    assert_includes initializer, "get '/toybaco/agent_seat_limit'"
    assert_includes initializer, 'Toybaco::AgentSeatLimit.install!'
    assert_includes File.read(File.join(ROOT, 'overlay/app/lib/toybaco/agent_seat_limit.rb')),
                    '::Account.prepend(AccountUsageLimits)'
    assert_includes File.read(File.join(ROOT, 'overlay/app/lib/toybaco/agent_seat_limit.rb')),
                    '::AccountUser.prepend(MembershipGuard)'
    refute_includes oidc, 'agent_seat_limit'
    refute_includes billing, 'agent_seat_limit'
    refute_includes controller, 'cancel'
    refute_includes controller, 'TOYBACO_E2E_STAGING_READY'
    refute_match(/sk_live|rk_live|whsec_/, controller)
  end

  def test_customer_shell_uses_lp_copy_and_tokens
    js = File.read(File.join(ROOT, 'overlay/app/public/brand-assets/toybaco-agent-seat.js'))
    css = File.read(File.join(ROOT, 'overlay/app/public/toybaco-brand.css'))
    injector = File.read(File.join(ROOT, 'overlay/app/lib/toybaco/brand_injector.rb'))

    assert_includes js, 'payload.title'
    assert_includes js, 'payload.message'
    refute_includes js, "var TITLE = '利用は3名まで'"
    assert_includes js, '/toybaco/agent_seat_limit?account_id='
    assert_includes js, 'settings\\/agents'
    assert_includes js, '担当者を追加'
    refute_includes js, 'Chatwoot'
    refute_includes js, 'iframe'
    refute_includes js, 'createElement(\'iframe\')'
    assert_includes css, '[data-toybaco-agent-seat-banner]'
    assert_includes css, '#1f3a5f'
    assert_includes css, '#163049'
    assert_includes css, '#fcfbf8'
    assert_includes injector, 'toybaco-agent-seat.js'
    refute_includes js, 'openid'
  end

  def test_rake_points_at_server_enforcement
    rake = File.read(File.join(ROOT, 'overlay/app/lib/tasks/toybaco.rake'))

    assert_includes rake, 'Toybaco::AgentSeatLimit'
    refute_includes rake, 'FOLLOW-UP(このPRでは実装しない): Light 3席'
  end
end
