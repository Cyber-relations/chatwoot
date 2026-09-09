# frozen_string_literal: true

require 'minitest/autorun'
require 'erb'
require_relative '../overlay/app/lib/toybaco/billing_cancel'
require_relative '../overlay/app/lib/toybaco/billing_access'

# ご契約内容からの解約は LP どおり2クリック。
# クリック1: 「解約する」 / クリック2: 確認の「解約する」(戻るで中止)。
# お支払い方法・OIDC・ライト3名・メール基盤・F3 は混ぜない。
class ChatwootBillingCancelTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  CANCEL_COPY = '解約は、管理画面から2クリックで手続きできます。'
  CONFIRM_TITLE = 'この契約を解約しますか？'
  CONFIRM_BODY = 'お申し出以降、次回分の請求は発生しません。日割りの返金はありません。'

  def view
    @view ||= File.read(File.join(ROOT, 'overlay/app/app/views/toybaco/billing/show.html.erb'))
  end

  def controller
    @controller ||= File.read(File.join(ROOT, 'overlay/app/app/controllers/toybaco/billing_controller.rb'))
  end

  def billing_routes
    @billing_routes ||= File.read(File.join(ROOT, 'overlay/app/config/initializers/toybaco_billing.rb'))
  end

  def oidc
    @oidc ||= File.read(File.join(ROOT, 'overlay/app/config/initializers/toybaco_oidc.rb'))
  end

  def test_period_end_cancel_has_no_proration
    params = Toybaco::BillingCancel.period_end_params

    assert_equal({ 'cancel_at_period_end' => 'true' }, params)
    refute params.key?('cancel_at')
    refute_includes params.values, 'false'
  end

  def test_two_clicks_are_cancel_then_cancel
    assert_includes view, 'id="cancel-open">解約する</button>'
    assert_includes view, 'id="cancel-confirm">解約する</button>'
    assert_includes view, 'id="cancel-back">戻る</button>'
    assert_includes view, 'id="cancel-dialog"'
    assert_includes view, "pathname + '/cancel'"
    refute_includes view, 'id="cancel-confirm">確認</button>'
    refute_includes view, 'やめる'
  end

  def test_cancel_copy_is_cycle_independent_and_confirmation_is_unchanged
    assert_includes view, CANCEL_COPY
    assert_includes view, CONFIRM_TITLE
    assert_includes view, CONFIRM_BODY
    refute_includes view, '管理画面から2クリックです'
    refute_includes view, '契約の縛りなし —'
  end

  def test_cancel_is_not_mixed_with_payment_methods
    assert_includes view, 'id="cancel-box"'
    assert_includes view, 'id="portal">お支払い方法・請求履歴</button>'
    refute_match(/id="portal"[^>]*>解約する/, view)
    refute_includes controller[controller.index('def cancel')..], 'billing_portal/sessions'
    refute_includes controller[controller.index('def cancel')..], "pathname + '/portal'"
  end

  def test_cancel_route_is_outside_oidc
    assert_includes billing_routes, "post '/toybaco/billing/cancel', to: 'toybaco/billing#cancel'"
    refute_includes oidc, '/toybaco/billing/cancel'
    refute_includes oidc, 'billing#cancel'
    assert_includes controller, 'def cancel'
    assert_includes controller, 'plan_change_service.cancel_subscription'
    service = File.read(File.join(ROOT, 'overlay/app/lib/toybaco/checkout/plan_change_cancellation.rb'))
    assert_includes service, 'Toybaco::BillingCancel.period_end_params'
  end

  def test_customer_copy_hides_vendor_and_out_of_scope
    blob = "#{view}\n#{controller}\n#{billing_routes}"

    refute_match(/Chatwoot|Postiz|Captain|キャプテン/i, view)
    refute_includes view, '3名'
    refute_includes view, 'ライト3'
    refute_match(/(?:^|[^A-Fa-f0-9])F3(?:[^A-Fa-f0-9]|$)/, view)
    refute_includes view, 'OIDC'
    refute_includes view, 'traffic'
    refute_includes view, '#FF5F57'
    refute_match(/sk_live|rk_live|whsec_/, blob)
  end

  def test_shell_colors_match_app_box
    assert_includes view, '--navy:#1F3A5F'
    assert_includes view, '--navy-deep:#163049'
    assert_includes view, '--surface:#FCFBF8'
  end

  def test_owner_without_admin_role_reads_saved_limits_without_mutation_controls
    [[true, 733, '契約に含まれる（月733件）'], [true, nil, '契約に含まれる（月上限なし）'],
     [false, 0, '対象外'], [nil, 500, '確認できません']].each do |feature, limit, label|
      context = Object.new
      context.instance_variable_set(:@account, Struct.new(:name).new('店舗'))
      context.instance_variable_set(:@plan, { name: '保存済み契約' })
      context.instance_variable_set(:@admin, false)
      context.instance_variable_set(:@contract, { 'entitlements' => { 'features' => { 'ai_reply' => feature },
                                                                    'limits' => { 'ai_replies' => limit } } })
      context.define_singleton_method(:number_with_delimiter) { |amount| amount.to_s }
      rendered = ERB.new(view).result(context.instance_eval { binding })
      assert_includes rendered, label
      assert_includes rendered, 'AI の表示はご契約上の利用枠です。応答の設定・稼働状況は受信箱でご確認ください。'
      assert_includes rendered, '契約の変更には管理者権限が必要です。'
      refute_includes rendered, '直近の請求額（税込）'
      refute_includes rendered, 'id="plan-change-panel"'
    end
  end
end

class ChatwootBillingAccessTest < Minitest::Test
  Access = Toybaco::BillingAccess
  Store = Toybaco::StoreFulfillment
  User = Struct.new(:id)
  Membership = Struct.new(:account_id, :user_id, :role) do
    def administrator?
      role == :administrator
    end
  end
  class Memberships < Array
    def find_by(user_id:)
      find { |membership| membership.user_id == user_id }
    end

    def exists?(user_id:)
      !find_by(user_id: user_id).nil?
    end
  end
  AccountRecord = Struct.new(:id, :internal_attributes, :account_users)

  def setup
    @user = User.new(11)
    @account = AccountRecord.new(1, { Access::OWNER_KEY => 11 }, Memberships.new)
    @membership = Membership.new(1, 11, :administrator)
    @account.account_users << @membership
  end

  def assert_access(view, manage, account = @account, user = @user)
    assert_equal({ can_view_billing: view, can_manage_billing: manage }, Access.permissions(account, user))
  end

  def test_recorded_owner_can_read_and_admin_role_is_still_required_for_management
    assert_access true, true
    @membership.role = :agent
    assert_access true, false
    assert_equal :agent, @membership.role
  end

  def test_another_admin_or_agent_is_not_the_owner
    @account.internal_attributes[Access::OWNER_KEY] = 22
    assert_access false, false
    @membership.role = :agent
    assert_access false, false
    assert_equal 22, @account.internal_attributes[Access::OWNER_KEY]
  end

  def test_missing_or_malformed_owner_never_infers_the_current_administrator
    [nil, 0, -1, 11.0, '11', '', [11], { 'user_id' => 11 }].each do |owner|
      @account.internal_attributes[Access::OWNER_KEY] = owner
      assert_access false, false
      actual = @account.internal_attributes[Access::OWNER_KEY]
      owner.nil? ? assert_nil(actual) : assert_equal(owner, actual)
    end
    @account.internal_attributes.delete(Access::OWNER_KEY)
    assert_access false, false
    refute @account.internal_attributes.key?(Access::OWNER_KEY)
  end

  def test_login_and_membership_in_the_exact_account_remain_required
    assert_access false, false, @account, nil
    @account.account_users.clear
    assert_access false, false
    other_membership = Membership.new(2, 11, :administrator)
    assert_equal({ can_view_billing: false, can_manage_billing: false },
                 Access.permissions(@account, @user, membership: other_membership))
    other_membership.account_id = 1
    other_membership.user_id = 22
    assert_equal({ can_view_billing: false, can_manage_billing: false },
                 Access.permissions(@account, @user, membership: other_membership))
  end

  def with_linked_child(valid: true)
    child = AccountRecord.new(2, {}, Memberships.new)
    child.account_users << Membership.new(2, 11, :administrator)
    binding = {
      'parent_account_id' => 1, 'subscription_id' => 'sub_parent', 'subscription_item_id' => 'si_store',
      'slot' => 1, 'child_account_id' => 2, 'administrator_id' => 22, 'addon_id' => 'opt-store',
      'addon_version' => 'fixture', 'stripe_price_id' => 'price_store', 'cycle' => 'month',
      'unit_amount' => 9800, 'contract' => {}
    }
    child.internal_attributes[Store::PURCHASE] = binding
    @account.internal_attributes['toybaco_subscription_id'] = 'sub_parent'
    @account.internal_attributes[Store::REGISTRY] = { 'si_store:1' => binding }
    parent = @account
    lookup = Object.new
    lookup.define_singleton_method(:find_by) { |id:| id == parent.id ? parent : nil }
    Access.const_set(:Account, lookup)
    Store.stub(:valid_child?, valid) { yield child, binding }
  ensure
    Access.send(:remove_const, :Account) if Access.const_defined?(:Account, false)
  end

  def test_child_uses_the_verified_parent_owner_and_does_not_promote_its_operator
    with_linked_child do |child, _binding|
      assert_access true, true, child
      refute child.internal_attributes.key?(Access::OWNER_KEY)
      operator = User.new(22)
      child.account_users << Membership.new(2, 22, :administrator)
      @account.account_users << Membership.new(1, 22, :administrator)
      assert_access false, false, child, operator
      assert_equal [11, 22], child.account_users.map(&:user_id)
    end
  end

  def test_parent_owner_needs_existing_membership_in_both_parent_and_child
    with_linked_child do |child, _binding|
      child.account_users.clear
      assert_access false, false, child
      assert_empty child.account_users
      child.account_users << Membership.new(2, 11, :agent)
      assert_access true, false, child
      @account.account_users.clear
      assert_access false, false, child
      assert_empty @account.account_users
    end
  end

  def test_child_rejects_conflicting_owner_broken_parent_binding_and_copied_binding
    with_linked_child do |child, binding|
      child.internal_attributes[Access::OWNER_KEY] = 22
      assert_access false, false, child
      child.internal_attributes[Access::OWNER_KEY] = 11.0
      assert_access false, false, child
      child.internal_attributes.delete(Access::OWNER_KEY)
      child.id = 3
      assert_access false, false, child
      child.id = 2
      @account.internal_attributes[Store::REGISTRY] = {}
      assert_access false, false, child
      @account.internal_attributes[Store::REGISTRY] = { 'si_store:1' => binding }
      @account.internal_attributes[Access::OWNER_KEY] = nil
      assert_access false, false, child
      @account.internal_attributes[Access::OWNER_KEY] = 11
      @account.internal_attributes[Store::PURCHASE] = binding
      assert_access false, false, child
    end
  end

  def test_child_requires_the_existing_contract_binding_validator_to_accept
    with_linked_child(valid: false) { |child, _binding| assert_access false, false, child }
  end

  def test_enterprise_guard_blocks_alternative_billing_without_restricting_operational_limits
    callbacks = []
    controller_class = Class.new do
      attr_reader :response, :denied

      define_singleton_method(:before_action) { |name, only:| callbacks << [name, only] }
      define_method(:current_user) { @user }
      define_method(:head) { |status| @denied = status }
    end
    controller_class.prepend(Toybaco::BillingAccess::EnterpriseControllerGuard)
    actions = callbacks.fetch(0).fetch(1)
    assert_equal %i[checkout subscription select_billing_currency toggle_deletion topup_checkout topup_options], actions
    refute_includes actions, :limits
    controller = controller_class.new
    controller.instance_variable_set(:@response, Struct.new(:headers).new({}))
    controller.instance_variable_set(:@account, @account)
    controller.instance_variable_set(:@current_account_user, @membership)
    controller.instance_variable_set(:@user, @user)
    controller.send(:require_toybaco_billing_owner)
    assert_nil controller.denied
    @account.internal_attributes[Access::OWNER_KEY] = 22
    controller.send(:require_toybaco_billing_owner)
    assert_equal :forbidden, controller.denied
    assert_equal 'no-store', controller.response.headers['Cache-Control']
  end
end
