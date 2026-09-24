# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require Rails.root.join('lib/toybaco/growth/retention_selection')
require Rails.root.join('lib/toybaco/growth/inbox_release')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoGrowthRetentionRuntimeTest < ActionDispatch::IntegrationTest
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true
  Selection = Toybaco::Growth::RetentionSelection
  Inventory = Toybaco::Growth::RetentionInventory

  def setup
    @account = create(:account)
    @owner = create(:user, :administrator, account: @account)
    @staff = create(:user, :administrator, account: @account)
    terms = Toybaco::PlanCatalog.default.definition('standard', Selection::VERSION)
    @account.update!(internal_attributes: { Toybaco::BillingAccess::OWNER_KEY => @owner.id,
      'toybaco_contract' => Toybaco::Entitlements.snapshot_for(terms, cycle: 'month'), 'toybaco_subscription_id' => 'sub_retention' })
    @inboxes = 3.times.map { create(:inbox, account: @account) }
    @foreign = create(:inbox)
    @rows = { 'inboxes' => @inboxes.map { |inbox| { 'id' => inbox.id.to_s, 'name' => inbox.name, 'created_at_us' => inbox.created_at.to_i } },
              'posting_accounts' => [{ 'id' => 'posting_a', 'name' => 'Store account', 'created_at_us' => 1 }],
              'posts' => [] }
    @inventory = Object.new
    rows = @rows
    @inventory.define_singleton_method(:read) { rows.deep_dup }
    @previous_flag = ENV['TOYBACO_GROWTH_RETENTION_ENABLED']
    ENV['TOYBACO_GROWTH_RETENTION_ENABLED'] = 'true'
    host! 'app.example.com'
  end

  def teardown
    ENV['TOYBACO_GROWTH_RETENTION_ENABLED'] = @previous_flag
    Current.reset
  end

  def service(user = @owner, target = 'free')
    Selection.new(@account, user, target: target, inventory: @inventory)
  end

  def choices
    { 'inboxes' => [@inboxes.last.id.to_s], 'posting_accounts' => [] }
  end

  def authenticated(user = @owner)
    reader = Struct.new(:user).new(user)
    Toybaco::Oidc::SessionReader.stub(:new, reader) do
      Inventory.stub(:new, @inventory) { yield }
    end
  end

  def endpoint
    "/toybaco/growth/retention?account_id=#{@account.id}&target=free"
  end

  def test_persists_only_preference_and_leaves_contract_grants_and_reservations_untouched
    before = @account.internal_attributes.deep_dup
    first = service.read
    saved = service.save!(selected: choices, revision: first.fetch('revision'))
    assert_equal choices, service.read.fetch('selected')
    assert_equal saved.fetch('revision'), service.read.fetch('revision')
    refute_equal first.fetch('revision'), saved.fetch('revision')
    assert_equal before, @account.reload.internal_attributes.except(Selection::KEY)
    assert_equal choices, @account.internal_attributes.dig(Selection::KEY, 'selected')
    assert_empty Toybaco::GrowthAiGrant.where(account_id: @account.id) if defined?(Toybaco::GrowthAiGrant)
  end

  def test_lost_response_does_not_overwrite_newer_preference
    first = service.read
    service.save!(selected: choices, revision: first.fetch('revision'))
    assert_raises(Selection::Changed) { service.save!(selected: first.fetch('selected'), revision: first.fetch('revision')) }
    assert_equal choices, service.read.fetch('selected')
  end

  def test_deleted_connection_is_replaced_by_creation_order_without_reusing_another_store_id
    service.save!(selected: choices, revision: service.read.fetch('revision'))
    @rows['inboxes'].pop
    result = service.read.fetch('selected')
    assert_equal [@inboxes.first.id.to_s], result.fetch('inboxes')
    assert_empty result.fetch('posting_accounts')
  end

  def test_connection_or_queue_changes_require_a_fresh_confirmation
    revision = service.read.fetch('revision')
    @rows['posts'] << { 'id' => 'new_post', 'integration_id' => 'posting_a', 'publish_at_us' => 1, 'held' => false }
    assert_raises(Selection::Changed) { service.save!(selected: choices, revision: revision) }
    refute @account.reload.internal_attributes.key?(Selection::KEY)
  end

  def test_other_store_selection_and_unknown_fields_are_rejected
    bad = choices.merge('inboxes' => [@foreign.id.to_s])
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { service.save!(selected: bad, revision: service.read.fetch('revision')) }
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { service.save!(selected: choices.merge('limit' => 500), revision: 'x') }
    refute @account.reload.internal_attributes.key?(Selection::KEY)
  end

  def test_admin_without_billing_ownership_cannot_read_or_write
    assert_raises(Selection::Forbidden) { service(@staff).read }
    revision = service.read.fetch('revision')
    @account.update!(internal_attributes: @account.internal_attributes.merge(Toybaco::BillingAccess::OWNER_KEY => @staff.id))
    assert_raises(Selection::Forbidden) { service.save!(selected: choices, revision: revision) }
  end

  def test_target_source_and_subscription_changes_do_not_reuse_old_selection
    first = service.read
    service.save!(selected: choices, revision: first.fetch('revision'))
    @account.update!(internal_attributes: @account.internal_attributes.merge('toybaco_subscription_id' => 'sub_new'))
    refute_equal choices, service.read.fetch('selected')
    assert_raises(Selection::Changed) { service.save!(selected: choices, revision: first.fetch('revision')) }
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { service(@owner, 'pro').read }
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { service(@owner, 'standard').read }
  end

  def test_suspended_store_and_legacy_contract_are_rejected
    @account.update!(status: :suspended)
    assert_raises(Selection::Forbidden) { service.read }
    @account.update!(status: :active, internal_attributes: @account.internal_attributes.merge('toybaco_contract' =>
      Toybaco::Entitlements.snapshot_for(Toybaco::PlanCatalog.default.legacy('standard'), cycle: 'month')))
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { service.read }
  end

  def test_real_route_renders_escaped_names_and_saves_choices
    @rows['inboxes'][0]['name'] = '<script>alert(1)</script>'
    authenticated do
      get endpoint
      assert_response :success
      assert_select 'h1', '継続する接続'
      assert_select 'input[type=checkbox]', 4
      assert_includes response.body, '&lt;script&gt;alert(1)&lt;/script&gt;'
      post endpoint, params: { selected: choices, revision: service.read.fetch('revision') }, as: :json,
                     headers: { 'Origin' => 'http://app.example.com', 'Sec-Fetch-Site' => 'same-origin' }
      assert_response :success
      assert_equal choices, response.parsed_body.fetch('selected')
      assert_equal 'no-store', response.headers['Cache-Control']
    end
  end

  def test_http_origin_staff_foreign_store_and_feature_gate
    authenticated do
      post endpoint, params: { selected: choices, revision: service.read.fetch('revision') }, as: :json,
                     headers: { 'Origin' => 'https://foreign.example', 'Sec-Fetch-Site' => 'cross-site' }
      assert_response :forbidden
      get "/toybaco/growth/retention?account_id=#{@foreign.account_id}&target=free"
      assert_response :forbidden
      ENV.delete('TOYBACO_GROWTH_RETENTION_ENABLED')
      get endpoint
      assert_response :not_found
    end
    authenticated(@staff) { get endpoint; assert_response :forbidden }
  end

  def test_real_inbox_reader_only_returns_current_store_metadata
    @account.update!(internal_attributes: @account.internal_attributes.merge('postiz' => { 'enabled' => false }))
    result = Inventory.new(@account, connector: -> { raise 'must not connect without Postiz mapping' }).read
    assert_equal @inboxes.map { |inbox| inbox.id.to_s }.sort, result.fetch('inboxes').map { |row| row.fetch('id') }.sort
    assert_empty result.fetch('posting_accounts')
    assert result.fetch('inboxes').all? { |row| row.keys.sort == %w[created_at_us held id name] }
  end

  def test_real_postgresql_read_is_readonly_tenant_scoped_and_counts_root_reservations_only
    organization = Toybaco::PostizSync.deterministic_organization_id(@account.id)
    @account.update_columns(internal_attributes: @account.internal_attributes.merge('postiz' => {
      'enabled' => false, 'organization_id' => organization
    }))
    connector = -> { posting_database(organization) }
    result = Inventory.new(@account, connector: connector).read
    assert_equal ['own'], result.fetch('posting_accounts').map { |row| row.fetch('id') }
    assert_equal ['root'], result.fetch('posts').map { |row| row.fetch('id') }
    assert_equal ['on', 'on'], @readonly_checks
    assert_equal Time.utc(2026, 9, 20, 0, 0, 0, 123456).to_i * 1_000_000 + 123456,
                 result.fetch('posts').first.fetch('publish_at_us')
    assert @posting_connection.finished?
    refute_includes result.to_json, 'fixture-secret'
    refute_includes result.to_json, 'fixture-body'
  ensure
    @posting_connection&.close unless @posting_connection&.finished?
  end

  def test_untrusted_postiz_mapping_fails_before_database_connection
    @account.update_columns(internal_attributes: @account.internal_attributes.merge('postiz' => {
      'enabled' => false, 'organization_id' => Toybaco::PostizSync.deterministic_organization_id(@foreign.account_id)
    }))
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) do
      Inventory.new(@account, connector: -> { raise 'must not read another organization' }).read
    end
  end

  def test_persisted_posting_and_inbox_fences_survive_new_contract_and_disabled_flags
    organization = managed_organization
    # Constructor reads the inbox snapshot first; install matching receipts
    # before that read, as the production coordinator does under its lock.
    db, value = retention_database(organization)
    acknowledge_retention(value, inboxes: [@inboxes.first.id.to_s])
    @account.update_columns(internal_attributes: @account.internal_attributes.merge('toybaco_subscription_id' => 'sub_repurchase'))
    before = @account.internal_attributes.deep_dup
    result = Inventory.new(@account, connector: -> { db }).read
    assert_equal [false, true, true], result.fetch('inboxes').map { |row| row.fetch('held') }
    assert_equal ['own'], result.fetch('posting_accounts').reject { |row| row.fetch('held') }.map { |row| row.fetch('id') }
    assert_equal ['held-channel'], result.fetch('posting_accounts').select { |row| row.fetch('held') }.map { |row| row.fetch('id') }
    assert_equal %w[draft root], result.fetch('posts').map { |row| row.fetch('id') }.sort
    assert_equal ['draft'], result.fetch('posts').select { |row| row.fetch('held') }.map { |row| row.fetch('id') }
    assert_equal before, @account.reload.internal_attributes
    assert_equal ['on', 'on', 'on', 'on'], @readonly_checks
    assert db.finished?
    refute_includes result.to_json, 'fixture-secret'
    refute_includes result.to_json, 'fixture-body'
  end

  def test_recorded_hold_is_not_lost_before_rails_acknowledgement
    org = managed_organization
    db, = retention_database(org)
    result = Inventory.new(@account, connector: -> { db }).read
    assert result.fetch('posts').find { |post| post['id'] == 'draft' }.fetch('held')
    refute @account.reload.internal_attributes.key?(Toybaco::Growth::PostingRetention::KEY)
  end

  def test_corrupt_posting_receipt_never_falls_back_to_unheld_inventory
    org = managed_organization
    db, = retention_database(org)
    db.exec(%q{UPDATE "ToybacoPostingRetention" SET "receiptHash" = repeat('0', 64)})
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { Inventory.new(@account, connector: -> { db }).read }
    assert db.finished?
  end

  def test_different_rails_confirmation_rejects_the_posting_inventory
    org = managed_organization
    db, value = retention_database(org)
    acknowledge_retention(value)
    attrs = @account.internal_attributes.deep_dup
    attrs[Toybaco::Growth::PostingRetention::KEY]['transition_id'] = 'b' * 64
    @account.update_columns(internal_attributes: attrs)
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { Inventory.new(@account, connector: -> { db }).read }
    assert db.finished?
  end

  def test_missing_table_or_row_with_a_known_fence_is_an_error
    org = managed_organization
    db, value = retention_database(org)
    acknowledge_retention(value)
    db.exec('DROP TABLE "ToybacoPostingRetention"')
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { Inventory.new(@account, connector: -> { db }).read }
    db, = retention_database(org)
    db.exec('DELETE FROM "ToybacoPostingRetention"')
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { Inventory.new(@account, connector: -> { db }).read }
  end

  def test_unrecorded_queue_and_published_held_root_are_not_claimed_as_safe
    org = managed_organization
    db, = retention_database(org)
    db.exec("UPDATE \"Post\" SET state = 'PUBLISHED' WHERE id = 'draft'")
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { Inventory.new(@account, connector: -> { db }).read }
    db, = retention_database(org)
    db.exec_params("INSERT INTO \"Post\" VALUES ('unexpected','own',$1,NOW(),NULL,NULL,'QUEUE','fixture-body')", [org])
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { Inventory.new(@account, connector: -> { db }).read }
  end

  def test_deleted_held_draft_is_not_counted_and_deleted_connection_is_not_replaced
    org = managed_organization
    db, = retention_database(org)
    db.exec("UPDATE \"Post\" SET \"deletedAt\" = NOW() WHERE id = 'draft'")
    db.exec("UPDATE \"Integration\" SET \"deletedAt\" = NOW() WHERE id = 'held-channel'")
    result = Inventory.new(@account, connector: -> { db }).read
    assert_equal ['root'], result.fetch('posts').map { |row| row.fetch('id') }
    assert_equal ['own'], result.fetch('posting_accounts').map { |row| row.fetch('id') }
  end

  def test_other_organization_hold_is_not_treated_as_the_current_store_fence
    org = managed_organization
    db, = retention_database(org)
    db.exec_params('UPDATE "ToybacoPostingRetention" SET "organizationId" = $1', ['foreign-org'])
    db.exec_params('UPDATE "ToybacoPostingRetentionHistory" SET "organizationId" = $1', ['foreign-org'])
    result = Inventory.new(@account, connector: -> { db }).read
    assert_equal ['root'], result.fetch('posts').map { |row| row.fetch('id') }
    refute result.fetch('posting_accounts').any? { |row| row.fetch('held') }
  end

  def test_missing_or_corrupt_history_never_becomes_an_unheld_store
    org = managed_organization
    ['DROP TABLE "ToybacoPostingRetentionHistory"', 'DELETE FROM "ToybacoPostingRetentionHistory"',
     'DELETE FROM "ToybacoPostingRetention"', %q{UPDATE "ToybacoPostingRetentionHistory" SET generation = 2},
     %q{UPDATE "ToybacoPostingRetentionHistory" SET "receiptHash" = repeat('0',64)}].each do |sql|
      db, = retention_database(org)
      db.exec(sql)
      assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { Inventory.new(@account, connector: -> { db }).read }
      assert db.finished?
    end
  end

  def test_successive_stop_reads_current_generation_and_rejects_stale_pointer_or_missing_parent
    org = managed_organization
    db, first = retention_database(org)
    second = next_retention_generation(db, first)
    acknowledge_retention(second)
    result = Inventory.new(@account, connector: -> { db }).read
    assert result['posting_accounts'].all? { |row| row['held'] }
    assert_equal %w[draft root], result['posts'].select { |row| row['held'] }.map { |row| row['id'] }.sort

    db, first = retention_database(org)
    next_retention_generation(db, first)
    db.exec_params('UPDATE "ToybacoPostingRetention" SET "transitionId"=$1, "policyHash"=$2, "receiptHash"=$3,
      policy=$4::jsonb, "keepIntegrationIds"=$5::jsonb, "keepPostIds"=$6::jsonb, "heldPostIds"=$7::jsonb',
                   first.values_at('transitionId', 'policyHash', 'receiptHash') + first.values_at('policy', 'keepIntegrationIds', 'keepPostIds', 'heldPostIds').map { |value| JSON.generate(value) })
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { Inventory.new(@account, connector: -> { db }).read }

    db, first = retention_database(org)
    second = next_retention_generation(db, first)
    acknowledge_retention(second)
    db.exec('DELETE FROM "ToybacoPostingRetentionHistory" WHERE generation=1')
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { Inventory.new(@account, connector: -> { db }).read }
  end

  def test_corrupt_inbox_state_stops_before_any_posting_read
    attrs = @account.internal_attributes.merge(Toybaco::Growth::InboxRetention::KEY => {})
    @account.update_columns(internal_attributes: attrs)
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) do
      Inventory.new(@account, connector: -> { flunk 'must not connect with a corrupt inbox fence' }).read
    end
  end

  def test_actual_held_page_works_after_free_return_and_after_repurchase_without_mutating
    @rows['inboxes'][0].merge!('name' => '<script>customer</script>', 'held' => true)
    @rows['posting_accounts'][0]['held'] = false
    @rows['posts'] = [{ 'id' => 'held-post', 'integration_id' => 'posting_a', 'publish_at_us' => 1, 'held' => true }]
    %w[free standard].each do |plan|
      terms = Toybaco::PlanCatalog.default.definition(plan, Selection::VERSION)
      @account.update_columns(internal_attributes: @account.internal_attributes.merge('toybaco_contract' =>
        Toybaco::Entitlements.snapshot_for(terms, cycle: plan == 'free' ? nil : 'month')))
      before = @account.internal_attributes.deep_dup
      authenticated do
        get "/toybaco/growth/held?account_id=#{@account.id}"
        assert_response :success
        assert_select 'h1', '接続の保留状況'
        assert_select 'li.held', 1
        assert_select '.note', text: '予約 1件が保留中'
        assert_select 'form', 0
        assert_select 'button', 0
        refute_includes response.body, '<script>customer</script>'
        assert_includes response.body, '&lt;script&gt;customer&lt;/script&gt;'
        assert_equal 'no-store', response.headers['Cache-Control']
      end
      assert_equal before, @account.reload.internal_attributes
    end
  end

  def test_held_page_current_ownership_feature_gate_and_invalid_state
    endpoint = "/toybaco/growth/held?account_id=#{@account.id}"
    authenticated(@staff) { get endpoint; assert_response :forbidden }
    authenticated do
      get "/toybaco/growth/held?account_id=#{@foreign.account_id}"
      assert_response :forbidden
      ENV.delete('TOYBACO_GROWTH_RETENTION_ENABLED')
      get endpoint
      assert_response :not_found
      ENV['TOYBACO_GROWTH_RETENTION_ENABLED'] = 'true'
      @inventory.define_singleton_method(:read) { raise Toybaco::Growth::RetentionPlan::Invalid }
      get endpoint
      assert_response :conflict
    end
    @account.update!(status: :suspended)
    assert_raises(Selection::Forbidden) { service.held }
  end

  def with_release_fixture
    previous_flag = ENV['TOYBACO_INBOX_RELEASE_ENABLED']
    ENV['TOYBACO_INBOX_RELEASE_ENABLED'] = 'true'
    state = { 'revision' => 'a' * 64, 'limit' => 4,
      'inboxes' => [{ 'id' => @inboxes.first.id.to_s, 'name' => '既存の窓口', 'held' => false },
        { 'id' => @inboxes.last.id.to_s, 'name' => '<script>fixture</script>', 'held' => true }] }
    service = Struct.new(:state, :calls, :failure) do
      def read = state.deep_dup
      def call(**input)
        raise failure if failure
        calls << input
        state['inboxes'].each { |row| row['held'] = false if input[:inbox_ids].include?(row['id']) }
        state['revision'] = 'b' * 64
        { 'binding' => 'fixture-private-receipt' }
      end
    end.new(state, [], nil)
    Toybaco::Checkout::Client.stub(:new, Object.new) do
      Toybaco::Growth::InboxRelease.stub(:new, ->(*) { service }) { yield service }
    end
  ensure
    ENV['TOYBACO_INBOX_RELEASE_ENABLED'] = previous_flag
  end

  def release_endpoint
    "/toybaco/growth/inbox-release?account_id=#{@account.id}"
  end

  def release_body
    { inbox_ids: [@inboxes.last.id.to_s], revision: 'a' * 64, request_id: 'a' * 64 }
  end

  def test_release_http_renders_brand_choices_safely_and_returns_only_current_public_state
    with_release_fixture do |service|
      authenticated do
        get "/toybaco/growth/held?account_id=#{@account.id}"
        assert_response :success
        assert_select 'a', text: '受信ボックスを再開', count: 1 do |links|
          assert_equal release_endpoint, links.first['href']
        end
        get release_endpoint
        assert_response :success
        assert_select 'h1', '受信ボックスを再開'
        assert_select 'input[checked][disabled]', 1
        assert_select 'button', '選んだ受信ボックスを再開'
        assert_select 'script[type="module"][src]', 1 do |scripts|
          digest = Digest::SHA256.file(Rails.public_path.join('toybaco-growth-inbox-release.mjs')).hexdigest
          assert_equal "/toybaco-growth-inbox-release.mjs?v=#{digest}", scripts.first['src']
        end
        assert_includes response.body, '&lt;script&gt;fixture&lt;/script&gt;'
        refute_includes response.body, '<script>fixture</script>'
        assert_equal 'no-store', response.headers['Cache-Control']
        post release_endpoint, params: release_body.merge(limit: 100_000), as: :json, headers: { 'Origin' => 'http://app.example.com' }
        assert_response :success
        assert_equal release_body, service.calls.first
        assert_equal %w[account_id inboxes limit revision], response.parsed_body.keys.sort
        assert_equal @account.id, response.parsed_body['account_id']
        refute response.parsed_body['inboxes'].any? { |row| row['held'] }
        refute_includes response.body, 'fixture-private-receipt'
      end
    end
  end

  def test_release_http_requires_owner_same_origin_json_and_both_rollout_flags
    with_release_fixture do |service|
      authenticated do
        post release_endpoint, params: release_body, as: :json
        assert_response :forbidden
        post release_endpoint, params: release_body, as: :json, headers: { 'Origin' => 'https://foreign.example' }
        assert_response :forbidden
        post release_endpoint, params: release_body, headers: { 'Origin' => 'http://app.example.com' }
        assert_response :forbidden
        ENV['TOYBACO_INBOX_RELEASE_ENABLED'] = 'false'
        get release_endpoint
        assert_response :not_found
        post release_endpoint, params: release_body, as: :json, headers: { 'Origin' => 'http://app.example.com' }
        assert_response :not_found
        ENV['TOYBACO_INBOX_RELEASE_ENABLED'] = 'true'
        ENV['TOYBACO_GROWTH_RETENTION_ENABLED'] = 'false'
        get release_endpoint
        assert_response :not_found
        ENV['TOYBACO_GROWTH_RETENTION_ENABLED'] = 'true'
        get "/toybaco/growth/inbox-release?account_id=#{@foreign.account_id}"
        assert_response :forbidden
      end
      authenticated(@staff) { get release_endpoint; assert_response :forbidden }
      authenticated(nil) { get release_endpoint; assert_response :unauthorized }
      assert_empty service.calls
    end
  end

  def test_release_http_sanitizes_provider_state_and_busy_errors_without_claiming_success
    with_release_fixture do |service|
      [Toybaco::Growth::InboxReleaseRecord::Invalid.new('fixture-private-provider-data'),
       Toybaco::Growth::InboxRetention::Busy.new, Toybaco::Checkout::Unavailable.new('fixture-private-provider-data')].each do |failure|
        service.failure = failure
        authenticated do
          post release_endpoint, params: release_body, as: :json, headers: { 'Origin' => 'http://app.example.com' }
          assert_response :conflict
          assert_match /画面を更新/, response.parsed_body['error']
          refute_includes response.body, 'fixture-private'
          refute response.parsed_body.key?('inboxes')
        end
      end
      assert_empty service.calls
    end
  end

  private

  def managed_organization
    org = Toybaco::PostizSync.deterministic_organization_id(@account.id)
    @account.update_columns(internal_attributes: @account.internal_attributes.merge('postiz' => { 'enabled' => false, 'organization_id' => org }))
    org
  end

  def retention_database(organization)
    db = posting_database(organization)
    db.exec('CREATE TEMP TABLE "ToybacoPostingRetention" ("organizationId" text, "transitionId" text, "policyHash" text,
      "receiptHash" text, policy jsonb, "keepIntegrationIds" jsonb, "keepPostIds" jsonb, "heldPostIds" jsonb)')
    db.exec('CREATE TEMP TABLE "ToybacoPostingRetentionHistory" ("organizationId" text, "transitionId" text, generation integer, "receiptHash" text, receipt jsonb)')
    policy = { 'organizationId' => organization, 'transitionId' => 'a' * 64,
      'keepIntegrationIds' => ['own'], 'scheduledPostsPerAccount' => 5 }
    policy_hash = Digest::SHA256.hexdigest(JSON.generate(policy))
    receipt_hash = Digest::SHA256.hexdigest(JSON.generate([policy_hash, ['own'], ['root'], ['draft']]))
    value = { 'organizationId' => organization, 'transitionId' => policy['transitionId'], 'policyHash' => policy_hash,
      'receiptHash' => receipt_hash, 'policy' => policy.merge('policyHash' => policy_hash), 'keepIntegrationIds' => ['own'],
      'keepPostIds' => ['root'], 'heldPostIds' => ['draft'] }
    values = value.values.map { |item| item.is_a?(Hash) || item.is_a?(Array) ? JSON.generate(item) : item }
    db.exec_params('INSERT INTO "ToybacoPostingRetention" VALUES ($1,$2,$3,$4,$5::jsonb,$6::jsonb,$7::jsonb,$8::jsonb)', values)
    db.exec_params('INSERT INTO "ToybacoPostingRetentionHistory" VALUES ($1,$2,1,$3,$4::jsonb)',
                   [organization, value['transitionId'], value['receiptHash'], JSON.generate(value)])
    db.exec_params('INSERT INTO "Integration" VALUES ($1,$2,$3,NOW(),NULL,$4)', ['held-channel', 'Held channel', organization, 'fixture-secret'])
    @readonly_checks.clear
    [db, value]
  end

  def next_retention_generation(db, first)
    policy = { 'organizationId' => first['organizationId'], 'transitionId' => 'b' * 64, 'keepIntegrationIds' => [],
      'scheduledPostsPerAccount' => 0, 'previousTransitionId' => first['transitionId'], 'previousReceiptHash' => first['receiptHash'] }
    policy_hash = Digest::SHA256.hexdigest(JSON.generate(policy))
    receipt_hash = Digest::SHA256.hexdigest(JSON.generate([policy_hash, [], [], %w[draft root]]))
    second = { 'organizationId' => first['organizationId'], 'transitionId' => policy['transitionId'], 'policyHash' => policy_hash,
      'receiptHash' => receipt_hash, 'policy' => policy.merge('policyHash' => policy_hash), 'keepIntegrationIds' => [],
      'keepPostIds' => [], 'heldPostIds' => %w[draft root] }
    db.exec('DELETE FROM "ToybacoPostingRetention"')
    db.exec_params('INSERT INTO "ToybacoPostingRetention" VALUES ($1,$2,$3,$4,$5::jsonb,$6::jsonb,$7::jsonb,$8::jsonb)',
                   second.values.map { |value| value.is_a?(Hash) || value.is_a?(Array) ? JSON.generate(value) : value })
    db.exec_params('INSERT INTO "ToybacoPostingRetentionHistory" VALUES ($1,$2,2,$3,$4::jsonb)',
                   [second['organizationId'], second['transitionId'], receipt_hash, JSON.generate(second)])
    db.exec(%q{UPDATE "Post" SET state='DRAFT' WHERE id IN ('root', 'child')})
    second
  end

  def acknowledge_retention(value, inboxes: nil)
    posting = { 'version' => 1, 'request_sha256' => 'c' * 64, 'organization_id' => value['organizationId'],
      'transition_id' => value['transitionId'], 'policy_hash' => value['policyHash'], 'receipt_hash' => value['receiptHash'],
      'kept_posts' => value['keepPostIds'].size, 'held_posts' => value['heldPostIds'].size, 'confirmed_at' => Time.now.to_i }
    attrs = @account.internal_attributes.merge(Toybaco::Growth::PostingRetention::KEY => posting)
    if inboxes
      fields = { 'version' => 1, 'account_id' => @account.id, 'transition_id' => value['transitionId'], 'plan_version' => Selection::VERSION,
        'keep_inbox_ids' => inboxes.sort, 'posting_receipt_hash' => value['receiptHash'], 'confirmed_at' => Time.now.to_i }
      attrs[Toybaco::Growth::InboxRetention::KEY] = fields.merge('receipt_hash' => Toybaco::Growth::RetentionSnapshot.fingerprint(fields))
    end
    @account.update_columns(internal_attributes: attrs)
  end


  def posting_database(organization)
    config = Account.connection_pool.db_config.configuration_hash
    @posting_connection = PG.connect(host: config[:host], port: config[:port], dbname: config[:database],
                                     user: config[:username], password: config[:password], connect_timeout: 5)
    db = @posting_connection
    db.exec('CREATE TEMP TABLE "Integration" (id text, name text, "organizationId" text, "createdAt" timestamp, "deletedAt" timestamp, token text)')
    db.exec('CREATE TEMP TABLE "Post" (id text, "integrationId" text, "organizationId" text, "publishDate" timestamp,
             "deletedAt" timestamp, "parentPostId" text, state text, content text)')
    db.exec_params('INSERT INTO "Integration" VALUES ($1,$2,$3,NOW(),NULL,$4)', ['own', 'Own store', organization, 'fixture-secret'])
    db.exec_params('INSERT INTO "Integration" VALUES ($1,$2,$3,NOW(),NULL,$4)', ['foreign', 'Another store', 'another-org', 'fixture-secret'])
    [['root', 'own', organization, nil, 'QUEUE'], ['child', 'own', organization, 'root', 'QUEUE'],
     ['draft', 'own', organization, nil, 'DRAFT'], ['published', 'own', organization, nil, 'PUBLISHED'],
     ['foreign-post', 'foreign', 'another-org', nil, 'QUEUE'], ['mismatched', 'foreign', organization, nil, 'QUEUE']].each do |id, integration, org, parent, state|
      db.exec_params("INSERT INTO \"Post\" VALUES ($1,$2,$3,'2026-09-20 00:00:00.123456',NULL,$4,$5,$6)",
                     [id, integration, org, parent, state, 'fixture-body'])
    end
    @readonly_checks = []
    checks = @readonly_checks
    db.define_singleton_method(:exec_params) do |query, values|
      checks << exec('SHOW transaction_read_only').getvalue(0, 0)
      super(query, values)
    end
    db
  end
end

require_relative 'toybaco_growth_posting_release_http_cases'
ToybacoGrowthRetentionRuntimeTest.include(ToybacoPostingReleaseHttpCases)
