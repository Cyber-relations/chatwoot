# frozen_string_literal: true

require 'minitest/autorun'
require 'erb'
require_relative '../overlay/app/lib/toybaco/growth/storage_usage'

# 仕様 3.1 容量と保存期間の最小実装。保存容量の条件(storage_bytes)を持つ契約だけ、
# 使用量・上限・保存期間・1 ファイル上限を案内する。拒否・停止・削除・通知メールは入れない。
class ChatwootBillingStorageNoticeTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  Usage = Toybaco::Growth::StorageUsage
  OPEN = '<% if @storage %>'
  NEXT_SECTION = "<% if growth && @admin && ENV['TOYBACO_GROWTH_RETENTION_ENABLED'] == 'true' %>"
  REFUSALS = %w[停止しました 停止します 停止中 受け付けません 受け付けできません 受け付けを停止 追加できません
                保存しません 保存できません 保存されません 削除します 削除されます 削除しました].freeze
  LIMIT = 50_000_000_000

  def view
    @view ||= File.read(File.join(ROOT, 'overlay/app/app/views/toybaco/billing/show.html.erb'))
  end

  def controller
    @controller ||= File.read(File.join(ROOT, 'overlay/app/app/controllers/toybaco/billing_controller.rb'))
  end

  def library
    @library ||= File.read(File.join(ROOT, 'overlay/app/lib/toybaco/growth/storage_usage.rb'))
  end

  def block
    start = view.index(OPEN)
    finish = view.index(NEXT_SECTION)
    refute_nil start, 'storage section is missing'
    refute_nil finish, 'connection hold section moved'
    view[start...finish]
  end

  def storage(level, used, reason: nil)
    { 'limit_bytes' => LIMIT, 'used_bytes' => used, 'ratio' => used&.fdiv(LIMIT), 'level' => level,
      'history_months' => 24, 'inbound_attachment_bytes' => 25_000_000, 'posting_file_bytes' => 250_000_000, 'reason' => reason }
  end

  def render(storage, plan_id: 'standard')
    context = Object.new
    context.instance_variable_set(:@storage, storage)
    context.instance_variable_set(:@contract, { 'plan_id' => plan_id })
    ERB.new(block).result(context.instance_eval { binding })
  end

  def renders
    { ok: render(storage('ok', 1_500_000_000)), warn80: render(storage('warn80', 40_000_000_000)),
      pro: render(storage('warn80', 40_000_000_000), plan_id: 'pro'), full: render(storage('full', LIMIT)),
      unavailable: render(storage(nil, nil, reason: 'unavailable')) }
  end

  def test_section_is_closed_by_storage_and_follows_the_existing_cards
    lines = block.lines.map(&:strip).reject(&:empty?)
    assert_equal OPEN, lines.first
    assert_equal '<% end %>', lines.last
    assert_equal block.scan(/<%\s*(?:if|unless)\b/).size, block.scan(/<%\s*end\s*%>/).size
    assert_equal 1, view.scan(OPEN).size
    assert_equal 1, block.scan('<section class="card"').size
    assert_includes block, '<h2 class="change-title" id="storage-heading">保存容量と保存期間</h2>'
    assert_operator view.index('id="plan-change-panel"'), :<, view.index(OPEN)
    assert_empty render(nil).strip
  end

  def test_section_uses_only_existing_classes_and_adds_no_style_or_script
    classes = block.scan(/class="([^"]+)"/).flatten.flat_map(&:split).uniq.sort
    assert_equal %w[badge card change-title note off row], classes
    refute_match(/<style|<script|style=/, block)
  end

  def test_rendered_copy_for_each_level
    ok, warn80, pro, full, unavailable = renders.values_at(:ok, :warn80, :pro, :full, :unavailable)
    assert_includes ok, '<span>使用中 1.5 GB / 上限 50 GB</span>'
    assert_includes ok, '<span>会話・送信履歴・公開済み投稿本文</span><span>直近 24 か月保存</span>'
    assert_includes ok, '<span>1 ファイル上限</span><span>受信添付 25MB・投稿素材 250MB</span>'
    assert_includes ok, '投稿素材は現在計上していません。'
    refute_includes ok, 'badge'
    assert_includes warn80, '<span class="badge off">上限の 80% に達しています</span> 不要な添付の削除や上位プランで容量を確保できます。'
    assert_includes pro, '<span class="badge off">上限の 80% に達しています</span> 不要な添付の削除で容量を確保できます。'
    refute_includes pro, '上位プラン'
    assert_includes full, '<span class="badge off">上限に達しています</span> 現在は追加の受け入れを止めていません。'
    assert_includes full, '整理はサポート（<a href="mailto:support@toybaco.jp">support@toybaco.jp</a>）へご相談ください。'
    assert_includes unavailable, '<p class="note" role="status">使用量を取得できません。時間をおいて再度お試しください。</p>'
    assert_includes unavailable, '<span>上限 50 GB</span>'
    refute_includes unavailable, '使用中'
  end

  def test_copy_never_claims_that_anything_is_refused_stopped_or_deleted
    rendered = renders.values.join
    REFUSALS.each do |phrase|
      refute_includes block, phrase
      refute_includes rendered, phrase
    end
    refute_match(/Chatwoot|Postiz|Active ?Storage|S3/i, rendered)
  end

  def test_controller_counts_only_contracts_with_storage_terms
    show = controller[controller.index('  def show')...controller.index('  def portal')]
    assert_operator show.index('@contract = Toybaco::Entitlements.contract_for(@account)'), :<, show.index('@storage = storage_usage')
    refute_includes show[show.index('rescue Toybaco::PlanCatalog::Invalid')..], 'storage'
    helper = controller[controller.index('  def storage_usage')...controller.index('  def load_actual_billing')]
    assert_includes helper, "limits = @contract&.dig('entitlements', 'limits')"
    assert_includes helper, "storage_bytes = limits && limits['storage_bytes']"
    assert_includes helper, 'return unless storage_bytes.is_a?(Integer) && storage_bytes.positive?'
    assert_includes helper, 'Toybaco::Growth::StorageUsage.new(@account, limits: limits).read'
    assert_includes controller, "require_relative '../../../lib/toybaco/growth/storage_usage'"
  end

  def test_usage_is_read_only_bounded_and_never_raises_database_errors
    assert_includes library, 'transaction(requires_new: true)'
    assert_equal "SET LOCAL statement_timeout = '5s'", Usage::TIMEOUT
    assert_includes library, 'rescue ActiveRecord::ActiveRecordError, PG::Error => e'
    assert_includes library, 'toybaco_storage_usage_unavailable account=#{@account.id} class=#{e.class}'
    assert_includes library, 'toybaco_storage_notice account=#{@account.id} level=#{level} used_bytes=#{used} limit_bytes=#{@limit}'
    refute_match(/e\.message|backtrace|internal_attributes|update|save|create|destroy|purge|perform_later|deliver|Sidekiq|Cron/,
                 library)
    sql = Usage::USAGE
    refute_match(/\b(?:INSERT|UPDATE|DELETE|TRUNCATE)\b/i, sql)
    assert_includes sql, 'WHERE blobs.id IN (SELECT links.blob_id FROM active_storage_attachments links'
    assert_includes sql, "links.record_type = 'Attachment' AND links.name = 'file' AND attachments.account_id = ?"
  end

  def test_levels_switch_exactly_at_80_and_100_percent
    assert_equal 'ok', Usage.level(0, LIMIT)
    assert_equal 'ok', Usage.level(39_999_999_999, LIMIT)
    assert_equal 'warn80', Usage.level(40_000_000_000, LIMIT)
    assert_equal 'warn80', Usage.level(49_999_999_999, LIMIT)
    assert_equal 'full', Usage.level(LIMIT, LIMIT)
    assert_equal 'full', Usage.level(LIMIT + 1, LIMIT)
  end

  def test_decimal_units_never_round_usage_up_to_the_limit
    assert_equal '0.0', Usage.used_gigabytes(0)
    assert_equal '1.5', Usage.used_gigabytes(1_599_999_999)
    assert_equal '49.9', Usage.used_gigabytes(49_999_999_999)
    assert_equal '50.0', Usage.used_gigabytes(LIMIT)
    assert_equal '1', Usage.decimal(1_000_000_000, Usage::GB)
    assert_equal '1.5', Usage.decimal(1_500_000_000, Usage::GB)
    assert_equal '100', Usage.decimal(100_000_000_000, Usage::GB)
    assert_equal '25', Usage.decimal(25_000_000, Usage::MB)
    assert_equal '250', Usage.decimal(250_000_000, Usage::MB)
  end

  def test_usage_requires_a_positive_integer_storage_limit
    [nil, 0, -1, 1.5, '50000000000'].each do |value|
      assert_raises(ArgumentError) { Usage.new(Object.new, limits: { 'storage_bytes' => value }) }
    end
    assert_raises(KeyError) { Usage.new(Object.new, limits: {}) }
  end
end
