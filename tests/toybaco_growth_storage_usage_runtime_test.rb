# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require Rails.root.join('lib/toybaco/growth/storage_usage')
require Rails.root.join('lib/toybaco/checkout/plan_change')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

# 仕様 3.1 容量と保存期間の最小実装。ご契約内容で使用量・上限・保存期間・1 ファイル上限を案内する。
# 使用量は表示のたびに数え、保存・通知メール・拒否・削除はしない。storage_bytes の無い契約では何も読まない。
class ToybacoGrowthStorageUsageRuntimeTest < ActionDispatch::IntegrationTest
  include FactoryBot::Syntax::Methods
  include ActiveJob::TestHelper
  self.use_transactional_tests = true
  Usage = Toybaco::Growth::StorageUsage
  GB = 1_000_000_000
  SECTION = 'section[aria-labelledby="storage-heading"]'

  def setup
    @old_key = ENV.delete('TOYBACO_STRIPE_KEY')
    @account = create(:account)
    @owner = create(:user, :administrator, account: @account)
    contract!('standard', '2026-09-25.1')
  end

  def teardown
    @old_key ? ENV['TOYBACO_STRIPE_KEY'] = @old_key : ENV.delete('TOYBACO_STRIPE_KEY')
    Current.reset
  end

  def contract!(plan, version)
    terms = Toybaco::PlanCatalog.default.definition(plan, version)
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: 'month'))
    @account.update!(internal_attributes: @account.reload.internal_attributes.merge(Toybaco::BillingAccess::OWNER_KEY => @owner.id))
  end

  def limits
    Toybaco::Entitlements.contract_for(@account.reload).dig('entitlements', 'limits')
  end

  def blob(bytes)
    ActiveStorage::Blob.create_before_direct_upload!(
      filename: 'fixture.bin', byte_size: bytes, checksum: Digest::MD5.base64digest("fixture-#{bytes}"),
      content_type: 'application/octet-stream', metadata: { 'identified' => true, 'analyzed' => true }
    )
  end

  # The social ingest path also saves the Attachment before its file is attached.
  def attach(account, blob)
    @messages ||= {}
    message = @messages[account.id] ||= create(:message, account: account)
    record = message.attachments.create!(account_id: account.id, file_type: :file)
    ActiveStorage::Attachment.create!(name: 'file', record: record, blob: blob)
  end

  def show_billing
    reader = Struct.new(:user).new(@owner)
    changes = Struct.new(:state).new({})
    Toybaco::Oidc::SessionReader.stub(:new, reader) do
      Toybaco::Checkout::Client.stub(:new, ->(*) { flunk 'the storage notice never reads Stripe' }) do
        Toybaco::Checkout::PlanChange.stub(:new, changes) { get "/toybaco/billing?account_id=#{@account.id}" }
      end
    end
  end

  def capture_log(&)
    io = StringIO.new
    Rails.stub(:logger, ActiveSupport::Logger.new(io), &)
    io.string.lines.map(&:chomp).grep(/toybaco_storage_/)
  end

  def capture_sql(&)
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
    statements
  end

  def notice(level, used, limit = 50 * GB)
    "toybaco_storage_notice account=#{@account.id} level=#{level} used_bytes=#{used} limit_bytes=#{limit}"
  end

  def with_blob_table_locked
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    blocker = PG.connect(host: config[:host], port: config[:port], dbname: config[:database], user: config[:username],
                         password: config[:password], connect_timeout: 5)
    blocker.exec("SET lock_timeout = '3s'")
    blocker.exec("SET idle_in_transaction_session_timeout = '30s'")
    blocker.exec('BEGIN')
    blocker.exec('LOCK TABLE active_storage_blobs IN ACCESS EXCLUSIVE MODE')
    yield
  ensure
    begin
      blocker&.exec('ROLLBACK')
    rescue PG::Error
      nil
    end
    blocker&.close
  end

  def test_reused_blob_counts_once_other_stores_are_excluded_and_nothing_is_written
    shared = blob(1_200_000_000)
    2.times { attach(@account, shared) }
    attach(@account, blob(300_000_000))
    other = create(:account)
    attach(other, blob(7 * GB))
    attach(other, shared)

    result = Usage.new(@account, limits: limits).read
    assert_equal [1_500_000_000, 50 * GB, 'ok', nil], result.values_at('used_bytes', 'limit_bytes', 'level', 'reason')
    assert_in_delta 0.03, result['ratio']
    assert_equal [24, 25_000_000, 250_000_000], result.values_at('history_months', 'inbound_attachment_bytes', 'posting_file_bytes')

    before = @account.reload.internal_attributes.deep_dup
    deliveries = ActionMailer::Base.deliveries.size
    log = nil
    statements = capture_sql { log = capture_log { assert_no_enqueued_jobs { show_billing } } }
    assert_response :ok
    assert_select "#{SECTION} h2", text: '保存容量と保存期間'
    assert_select "#{SECTION} .row span", text: '使用中 1.5 GB / 上限 50 GB'
    assert_select "#{SECTION} .row span", text: '直近 24 か月保存'
    assert_select "#{SECTION} .row span", text: '受信添付 25MB・投稿素材 250MB'
    assert_select "#{SECTION} .note", text: /投稿素材は現在計上していません。/
    assert_select "#{SECTION} .badge", count: 0
    assert_empty log
    usage = statements.grep(/active_storage_blobs/)
    assert_equal 1, usage.size
    assert_equal Usage::TIMEOUT, statements[statements.index(usage.first) - 1]
    assert_equal before, @account.reload.internal_attributes
    assert_equal deliveries, ActionMailer::Base.deliveries.size
  end

  def test_levels_switch_exactly_at_80_and_100_percent_with_one_numbers_only_warning
    stored = blob(1)
    attach(@account, stored)
    [[39_999_999_999, 'ok'], [40 * GB, 'warn80'], [49_999_999_999, 'warn80'], [50 * GB, 'full'], [(50 * GB) + 1, 'full']].each do |bytes, level|
      stored.update_columns(byte_size: bytes)
      result = nil
      log = capture_log { result = Usage.new(@account, limits: limits).read }
      assert_equal level, result['level'], bytes
      assert_equal(level == 'ok' ? [] : [notice(level, bytes)], log)
    end
  end

  def test_page_explains_80_and_100_percent_without_claiming_a_refusal
    stored = blob(40 * GB)
    attach(@account, stored)
    log = capture_log { show_billing }
    assert_response :ok
    assert_select "#{SECTION} .row span", text: '使用中 40.0 GB / 上限 50 GB'
    assert_select "#{SECTION} .badge.off", text: '上限の 80% に達しています'
    assert_select "#{SECTION} .note", text: /不要な添付の削除や上位プランで容量を確保できます。/
    assert_equal [notice('warn80', 40 * GB)], log

    stored.update_columns(byte_size: 49_999_999_999)
    show_billing
    assert_select "#{SECTION} .row span", text: '使用中 49.9 GB / 上限 50 GB'

    stored.update_columns(byte_size: 50 * GB)
    log = capture_log { show_billing }
    assert_response :ok
    assert_select "#{SECTION} .badge.off", text: '上限に達しています'
    assert_select "#{SECTION} .note", text: /現在は追加の受け入れを止めていません。整理はサポート（support@toybaco.jp）へご相談ください。/
    assert_select "#{SECTION} a[href='mailto:support@toybaco.jp']", count: 1
    section = css_select(SECTION).text
    %w[停止しました 受け付けません 追加できません 保存しません 削除します].each { |phrase| refute_includes section, phrase }
    assert_equal [notice('full', 50 * GB)], log
  end

  def test_pro_is_not_offered_a_higher_plan
    contract!('pro', '2026-09-25.1')
    attach(@account, blob(80 * GB))
    show_billing
    assert_response :ok
    assert_select "#{SECTION} .row span", text: '使用中 80.0 GB / 上限 100 GB'
    assert_select "#{SECTION} .note", text: /不要な添付の削除で容量を確保できます。/
    assert_select SECTION, text: /上位プラン/, count: 0
  end

  def test_contracts_without_storage_terms_show_nothing_and_never_count
    attach(@account, blob(GB))
    contract!('standard', '2026-09-06.1')
    statements = capture_sql { show_billing }
    assert_response :ok
    assert_nil controller.instance_variable_get(:@storage)
    assert_select SECTION, count: 0
    refute_includes response.body, '保存容量と保存期間'
    assert_empty statements.grep(/active_storage|statement_timeout/i)

    legacy = @account.internal_attributes.except('toybaco_contract', 'toybaco_plan_version').merge('toybaco_plan' => 'light')
    @account.update!(internal_attributes: legacy)
    statements = capture_sql { show_billing }
    assert_response :ok
    assert_equal 'legacy-unversioned', Toybaco::Entitlements.contract_for(@account.reload)['plan_version']
    assert_nil controller.instance_variable_get(:@storage)
    assert_select SECTION, count: 0
    assert_empty statements.grep(/active_storage|statement_timeout/i)
  end

  def test_statement_timeout_reports_unavailable_and_still_renders_the_page
    log = nil
    usage = []
    callback = ->(event) { usage << event if event.payload[:sql].to_s.include?('active_storage_blobs') }
    with_blob_table_locked do
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { log = capture_log { show_billing } }
    end
    assert_response :ok
    assert_select "#{SECTION} p.note[role=status]", text: '使用量を取得できません。時間をおいて再度お試しください。'
    assert_select "#{SECTION} .row span", text: '上限 50 GB'
    assert_select SECTION, text: /使用中/, count: 0
    assert_select '.plan-name', text: 'スタンダード プラン'
    assert_equal 1, usage.size
    assert_match(/QueryCanceled/, usage.first.payload.fetch(:exception).first)
    # Only the usage query is timed, so a slow first request cannot blur 5s against the 14s connection default.
    assert_operator usage.first.duration, :>=, 4_500, 'the usage query waited on the lock until its own timeout'
    assert_operator usage.first.duration, :<, 10_000, 'the 5s storage timeout, not the 14s connection default, ended the wait'
    assert_equal ["toybaco_storage_usage_unavailable account=#{@account.id} class=ActiveRecord::QueryCanceled"], log
  end
end
