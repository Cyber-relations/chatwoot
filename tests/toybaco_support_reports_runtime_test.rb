# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require 'ostruct'
require 'devise/test/integration_helpers'
require Rails.root.join('lib/toybaco/support/reports')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoSupportReportsRuntimeTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  self.use_transactional_tests = true
  Reports = Toybaco::Support::Reports

  def setup
    @adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @account = FactoryBot.create(:account)
    @user = FactoryBot.create(:user, :administrator, account: @account)
    @operations = FactoryBot.create(:super_admin)
    @billing = FactoryBot.create(:super_admin)
    @environment = %w[TOYBACO_SUPPORT_OPERATIONS_OWNER_ID TOYBACO_SUPPORT_BILLING_OWNER_ID].to_h { |key| [key, ENV[key]] }
    ENV['TOYBACO_SUPPORT_OPERATIONS_OWNER_ID'] = @operations.id.to_s
    ENV['TOYBACO_SUPPORT_BILLING_OWNER_ID'] = @billing.id.to_s
    @account.update!(internal_attributes: @account.internal_attributes.merge('toybaco_billing_owner_user_id' => @user.id))
  end

  def teardown
    @environment.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    ActiveJob::Base.queue_adapter = @adapter
    Current.reset
  end

  def enabled(user: @user, reports: true)
    original = GlobalConfigService.method(:load)
    config = lambda do |name, *args|
      case name
      when 'TOYBACO_SUPPORT_ENABLED' then true
      when 'TOYBACO_SUPPORT_REPORTS_ENABLED' then reports
      else original.call(name, *args)
      end
    end
    GlobalConfigService.stub(:load, config) do
      Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: user)) { yield }
    end
  end

  def submit(category: 'product', article: 'reply', request_id: SecureRandom.uuid, account: @account, origin: 'http://www.example.com')
    post '/toybaco/support/reports', params: { account_id: account.id, request_id: request_id, category: category, article_id: article },
                                      headers: { 'Origin' => origin }, as: :json
  end

  def test_intake_assigns_owner_and_stores_only_registered_diagnostic_codes
    before = Toybaco::GrowthAiOperation.count
    enabled do
      submit
      assert_response :success
      assert_equal '受付済み', response.parsed_body.dig('report', 'state')
    end
    record = Toybaco::SupportReport.last
    assert_equal @operations.id, record.assignee_id
    assert_equal @account.id, record.account_id
    assert_equal @user.id, record.user_id
    assert_equal 'reply', record.article_id
    assert_equal 2, record.diagnostics.length
    record.diagnostics.each { |check| assert_equal %w[id state], check.keys.sort }
    assert_in_delta 30.days, record.diagnostics_expires_at - record.created_at, 2
    assert_in_delta 90.days, record.expires_at - record.created_at, 2
    assert_equal before, Toybaco::GrowthAiOperation.count
  end

  def test_retries_do_not_duplicate_and_changed_payload_is_rejected
    request = SecureRandom.uuid
    enabled do
      submit(request_id: request)
      receipt = response.parsed_body
      submit(request_id: request)
      assert_equal receipt, response.parsed_body
      submit(request_id: request, category: 'security')
      assert_response :unprocessable_entity
    end
    assert_equal 1, Toybaco::SupportReport.where(account_id: @account.id).count
  end

  def test_cross_store_unknown_article_and_cross_origin_are_rejected
    enabled do
      submit(account: FactoryBot.create(:account))
      assert_response :forbidden
      submit(article: 'gmail')
      assert_response :forbidden
      submit(article: 'unregistered')
      assert_response :forbidden
      submit(origin: 'https://elsewhere.example')
      assert_response :forbidden
    end
    assert_empty Toybaco::SupportReport.where(account_id: @account.id)
  end

  def test_unassigned_owner_and_disabled_intake_never_accept_a_report
    enabled(reports: false) { submit; assert_response :forbidden }
    ENV['TOYBACO_SUPPORT_BILLING_OWNER_ID'] = @user.id.to_s
    enabled { submit; assert_response :forbidden }
    assert_empty Toybaco::SupportReport.where(account_id: @account.id)
  end

  def test_billing_requires_actual_contract_owner_and_assigns_billing_owner
    enabled { submit(category: 'billing', article: 'billing'); assert_response :success }
    assert_equal @billing.id, Toybaco::SupportReport.last.assignee_id
    @account.update!(internal_attributes: @account.internal_attributes.except('toybaco_billing_owner_user_id'))
    enabled { submit(category: 'billing', article: ''); assert_response :forbidden }
  end

  def test_other_member_cannot_read_report_and_removed_membership_cannot_submit
    enabled { submit }
    other = FactoryBot.create(:user, :administrator, account: @account)
    enabled(user: other) do
      get '/toybaco/support/reports', params: { account_id: @account.id }
      assert_response :success
      assert_empty response.parsed_body.fetch('reports')
    end
    @account.account_users.where(user_id: @user.id).delete_all
    enabled { submit; assert_response :forbidden }
  end

  def test_user_limit_keeps_existing_receipts_readable_and_retriable
    requests = Array.new(20) { SecureRandom.uuid }
    enabled do
      requests.each { |request| submit(request_id: request); assert_response :success }
      submit
      assert_response :too_many_requests
      submit(request_id: requests.first)
      assert_response :success
      get '/toybaco/support/reports', params: { account_id: @account.id }
      assert_equal 20, response.parsed_body.fetch('reports').length
    end
  end

  def test_configured_owner_queue_and_updates_cannot_cross_roles
    enabled do
      submit
      product = Toybaco::SupportReport.last
      submit(category: 'billing', article: 'billing')
      billing = Toybaco::SupportReport.last
      sign_in @operations, scope: :super_admin
      # Ruby-only fixtures render the real controller, layout, forms and rows.
      # Compiled assets are verified separately in the production image smoke.
      ViteRuby.instance.stub(:dev_server_running?, true) do
        get '/super_admin/toybaco_support', env: { 'action_dispatch.show_exceptions' => :none }
      end
      failure_page = Nokogiri::HTML(response.body)
      failure_page.css('style, script').remove
      failure = failure_page.text.gsub(/\s+/, ' ').strip.first(3000) unless response.successful?
      assert_response :success, failure
      assert_includes response.body, "店舗 #{@account.id}"
      patch "/super_admin/toybaco_support/#{billing.id}", params: { state: 'resolved' }
      assert_response :not_found
      patch "/super_admin/toybaco_support/#{product.id}", params: { state: 'reviewing' }
      assert_response :redirect
      assert_equal 'reviewing', product.reload.state
      patch "/super_admin/toybaco_support/#{product.id}", params: { state: 'resolved' }
      assert_response :redirect
      assert_equal 'fixed', product.reload.resolution
      assert_equal 'received', billing.reload.state
    end
  end

  def test_queue_pagination_keeps_older_reports_accessible_without_duplicates
    enabled { submit }
    first = Toybaco::SupportReport.last
    attributes = first.attributes.except('id')
    Toybaco::SupportReport.insert_all!(Array.new(100) { attributes.merge('request_id' => SecureRandom.uuid) })
    sign_in @operations, scope: :super_admin
    ViteRuby.instance.stub(:dev_server_running?, true) do
      get '/super_admin/toybaco_support'
      assert_response :success
      page = Nokogiri::HTML(response.body)
      assert_equal 100, page.css('tbody tr').length
      refute_includes response.body, "##{first.id}<br>"
      cursor_url = page.at_css('nav[aria-label="受付のページ"] a[href*="before="]')['href']
      get cursor_url
      assert_response :success
      assert_equal 1, Nokogiri::HTML(response.body).css('tbody tr').length
      assert_includes response.body, "##{first.id}<br>"
      refute_includes response.body, '前の100件'
    end
  end

  def test_queue_rejects_invalid_cursor_and_keeps_roles_on_following_pages
    enabled { submit(category: 'billing', article: 'billing') }
    sign_in @operations, scope: :super_admin
    get '/super_admin/toybaco_support', params: { before: 'not-an-id' }
    assert_response :bad_request
    ViteRuby.instance.stub(:dev_server_running?, true) do
      get '/super_admin/toybaco_support', params: { before: Toybaco::SupportReport.last.id + 1 }
    end
    assert_response :success
    assert_empty Nokogiri::HTML(response.body).css('tbody tr')
  end

  def test_owner_rotation_revokes_previous_queue_access
    enabled { submit }
    sign_in @operations, scope: :super_admin
    ENV['TOYBACO_SUPPORT_OPERATIONS_OWNER_ID'] = @billing.id.to_s
    get '/super_admin/toybaco_support'
    assert_response :forbidden
  end

  def test_retention_removes_diagnostics_at_thirty_days_and_report_at_ninety
    enabled { submit }
    record = Toybaco::SupportReport.last
    Reports.expire!(now: record.diagnostics_expires_at)
    assert_empty record.reload.diagnostics
    assert_equal 'received', record.state
    Reports.expire!(now: record.expires_at)
    refute Toybaco::SupportReport.exists?(record.id)
  end
end
