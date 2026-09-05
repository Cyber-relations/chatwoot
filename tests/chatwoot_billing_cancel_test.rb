# frozen_string_literal: true

require 'minitest/autorun'
require 'erb'
require_relative '../overlay/app/lib/toybaco/billing_cancel'

# ご契約内容からの解約は LP どおり2クリック。
# クリック1: 「解約する」 / クリック2: 確認の「解約する」(戻るで中止)。
# お支払い方法・OIDC・ライト3名・メール基盤・F3 は混ぜない。
class ChatwootBillingCancelTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  LP_LINE = '月払いは契約の縛りなし。解約はいつでも、管理画面から2クリック'
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

  def test_confirm_copy_is_lp_words_uncut
    assert_includes view, LP_LINE
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

  def test_ai_contract_label_uses_saved_limits_and_does_not_disclose_staff_billing
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
      assert_includes rendered, '請求情報は管理者の方が確認できます。'
      refute_includes rendered, '直近の請求額（税込）'
      refute_includes rendered, 'id="plan-change-panel"'
    end
  end
end
