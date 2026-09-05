# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../overlay/app/lib/toybaco/ai_reply_mode'

# 受信箱の AI 一次応答は LP の2モード(全自動 / 下書き)だけ。
# Captain / Auto / Draft は客面に出さない。AI設定の更新で既存契約を変更しない。
class ChatwootAiReplyModeTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  MODE = Toybaco::AiReplyMode

  def test_modes_are_exactly_japanese_auto_and_draft
    assert_equal %w[auto draft], MODE::MODES
    assert_equal({ 'auto' => '全自動', 'draft' => '下書き' }, MODE::LABELS)
    assert_equal 'auto', MODE::DEFAULT
    assert_equal '全自動', MODE.label('auto')
    assert_equal '下書き', MODE.label('draft')
    assert_equal '全自動', MODE.label(nil)
    assert_equal '下書き', MODE.label('下書き')
    assert_equal 'auto', MODE.normalize('全自動')
    assert_equal 'draft', MODE.normalize('下書き')
    refute_includes MODE::LABELS.values, 'Auto'
    refute_includes MODE::LABELS.values, 'Draft'
  end

  def test_payload_exposes_japanese_labels_only
    payload = MODE.payload('draft')
    assert_equal 'draft', payload['mode']
    assert_equal '下書き', payload['label']
    assert_equal %w[全自動 下書き], payload['modes'].map { |row| row['label'] }
    blob = payload.to_s
    refute_match(/Captain|キャプテン|Copilot|Auto|Draft/, blob)
  end

  def test_controller_is_japanese_json_and_hides_vendor_names
    controller = File.read(File.join(ROOT, 'overlay/app/app/controllers/toybaco/ai_reply_controller.rb'))
    routes = File.read(File.join(ROOT, 'overlay/app/config/initializers/toybaco_oidc.rb'))

    assert_includes controller, 'Toybaco::AiReplyMode'
    assert_includes controller, 'api_access_token'
    refute_includes controller, 'Captain'
    refute_includes controller, 'Copilot'
    refute_match(/sk_live|rk_live|whsec_/, controller)
    assert_includes routes, "get '/toybaco/ai_reply_mode'"
    assert_includes routes, "put '/toybaco/ai_reply_mode'"
  end

  def test_inbox_overlay_wires_two_modes_outside_captain_panel
    js = File.read(File.join(ROOT, 'overlay/app/public/brand-assets/toybaco-post-entry.js'))
    css = File.read(File.join(ROOT, 'overlay/app/public/toybaco-brand.css'))

    assert_includes js, "var AI_NAV_LABEL = 'AI応答'"
    assert_includes js, "AI_MODE_LABELS[AI_MODE_AUTO] = '全自動'"
    assert_includes js, "AI_MODE_LABELS[AI_MODE_DRAFT] = '下書き'"
    refute_includes js, 'injectAiMode'
    assert_includes js, 'ensureComposerAiBar()'
    assert_includes js, '/toybaco/ai_reply_mode?account_id='
    refute_includes js, 'openCaptain'
    refute_match(/href = ['"][^'"]*captain/, js)
    refute_includes css, '[data-toybaco-ai-mode-entry]'
    assert_includes css, '[data-toybaco-ai-mode-bar]'
    assert_includes css, '[data-toybaco-ai-mode-panel]'
  end

  def test_mode_api_is_on_overlay_files_the_gate_copies
    controller = File.read(File.join(ROOT, 'overlay/app/app/controllers/toybaco/ai_reply_controller.rb'))
    lib = File.read(File.join(ROOT, 'overlay/app/lib/toybaco/ai_reply_mode.rb'))
    js = File.read(File.join(ROOT, 'overlay/app/public/brand-assets/toybaco-post-entry.js'))

    assert_includes lib, "ATTR = 'toybaco_ai_reply_mode'"
    assert_includes lib, "'全自動'"
    assert_includes lib, "'下書き'"
    assert_includes controller, 'Toybaco::AiReplyMode.write_to!(@account, params[:mode])'
    assert_includes js, "method: 'PUT'"
    assert_includes js, '/toybaco/ai_reply_mode?account_id='
    refute_includes controller, 'bot/handler.py'
  end

  def test_mode_updates_preserve_existing_contract_version_and_entitlements
    contract = {
      'schema_version' => 1, 'plan_id' => 'retained-plan', 'plan_version' => '2024-06.3',
      'name' => '既存の個別契約', 'cycle' => 'year', 'legacy' => true,
      'entitlements' => {
        'features' => { 'channel_instagram' => false, 'posting' => true, 'ai_reply' => true },
        'limits' => { 'agents' => 7, 'stores' => 2, 'ai_replies' => 350 }
      },
      'addons' => [{ 'id' => 'manual-posting', 'version' => '2024-06.1', 'quantity' => 1,
                     'source' => 'legacy_manual', 'terms' => { 'scope' => 'account', 'features' => { 'posting' => true } } }]
    }
    existing = {
      'toybaco_plan' => contract['plan_id'], 'toybaco_plan_version' => contract['plan_version'],
      'toybaco_cycle' => contract['cycle'], 'toybaco_contract' => contract,
      'toybaco_contract_addons' => contract['addons'], 'toybaco_subscription_id' => 'sub_retained',
      'postiz' => { 'enabled' => true, 'organization_id' => 'org_retained' }
    }
    account = Struct.new(:internal_attributes).new(Marshal.load(Marshal.dump(existing)))
    persisted = nil
    account.define_singleton_method(:save!) do
      persisted = Marshal.load(Marshal.dump(internal_attributes))
      true
    end

    %w[draft auto].each do |mode|
      assert_equal mode, MODE.write_to!(account, mode)
      refute_nil persisted, 'AI mode must be saved'
      assert_equal existing.merge(MODE::ATTR => mode), persisted,
                   'saving AI mode must preserve the entire historical contract and access metadata'
      account.internal_attributes = Marshal.load(Marshal.dump(persisted))
      assert_equal mode, MODE.read_from(account), 'saved mode must survive reloading attributes'
    end
  end
end
