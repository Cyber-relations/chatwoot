# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'active_support/testing/time_helpers'
require_relative 'toybaco_growth_purchase_stripe_fixture'
require_relative 'toybaco_opening_fixture'
require Rails.root.join('lib/toybaco/growth/opening_fulfillment')
require Rails.root.join('lib/toybaco/growth/opening_onboarding')

class ToybacoOpeningOnboardingRuntimeTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers
  include ToybacoOpeningFixture
  Growth = Toybaco::Growth
  NOW = Time.utc(2026, 9, 24, 12)
  ENVIRONMENT = { 'MAILER_INBOUND_EMAIL_DOMAIN' => 'inbox.staging.toybaco.jp', 'RAILS_INBOUND_EMAIL_SERVICE' => 'ses',
                  'ACTION_MAILBOX_SES_SNS_TOPIC' => 'arn:aws:sns:ap-northeast-1:123456789012:fixture' }.freeze

  def opening(industry: nil)
    @client.sessions[@session_id]['custom_fields'] << { 'key' => 'industry', 'dropdown' => { 'value' => industry } } if industry
    event = accept
    fulfill(event)
    opening_request(event)
  end

  def setup_opening(row, ready: true)
    resolver = Object.new
    resolver.define_singleton_method(:records) { |_| ready ? [Toybaco::InboundEmail::TOKYO_MX] : [] }
    Growth::OpeningOnboarding.new(row, environment: ENVIRONMENT, resolver: resolver).call
  end

  def latest(row)
    Toybaco::OpeningNotice.where(opening_request_id: row.id).order(:id).last
  end

  def notices_enabled(&block)
    Growth::OpeningNotices.stub(:enabled?, true, &block)
  end

  def retry_notice(row, notice, **options)
    Growth::OpeningNotices.retry!(row, actor_id: row.owner_id, request_id: SecureRandom.uuid, previous_id: notice.id, **options)
  end

  def test_real_industry_pack_and_initial_inbox_commit_once_with_queued_minimal_guidance
    row = opening(industry: 'retailec')
    setup_opening(row)
    assert_equal ['ready', 'applied', 'ready'], row.reload.values_at('onboarding_state', 'industry_state', 'inbox_state')
    account = Account.find(row.account_id)
    assert_equal 'retail-ec', account.internal_attributes['toybaco_industry']
    assert_operator account.canned_responses.count, :>, 0
    assert_equal 1, account.inboxes.count
    assert_equal [row.owner_id], InboxMember.where(inbox_id: row.inbox_id).pluck(:user_id)
    setup_opening(row)
    assert_equal 1, Toybaco::OpeningNotice.where(opening_request_id: row.id).count
    assert_equal 'queued', latest(row).state
    refute_includes latest(row).attributes.to_json, @email
    assert_equal NOW + 10.years, latest(row).retain_until
  end

  def test_unready_inbound_is_not_complete_and_recovers_without_overwriting_edited_pack
    row = opening(industry: 'food')
    setup_opening(row, ready: false)
    assert_equal ['pending', 'applied', 'blocked'], row.reload.values_at('onboarding_state', 'industry_state', 'inbox_state')
    assert_nil row.inbox_id
    canned = Account.find(row.account_id).canned_responses.first
    canned.update!(content: 'Owner edited fixture')
    travel_to NOW + 31
    setup_opening(row)
    assert_equal 'ready', row.reload.onboarding_state
    assert_equal 'Owner edited fixture', canned.reload.content
    assert_equal 1, Toybaco::OpeningNotice.where(opening_request_id: row.id).count
  end

  def test_setup_commit_failure_rolls_back_pack_inbox_and_notice_but_preserves_attempt_budget
    row = opening(industry: 'food')
    Growth::OpeningNotices.stub(:initial!, ->(*) { raise IOError, 'fixture after inbox insert' }) do
      assert_raises(IOError) { setup_opening(row) }
    end
    assert_equal ['pending', 'pending', 1], row.reload.values_at('industry_state', 'inbox_state', 'onboarding_attempts')
    assert_empty Account.find(row.account_id).inboxes
    assert_empty Account.find(row.account_id).canned_responses
    refute latest(row)
    travel_to NOW + 31
    setup_opening(row)
    assert_equal 'ready', row.reload.onboarding_state
  end

  def test_invalid_industry_rejects_store_before_creation
    @client.sessions[@session_id]['custom_fields'] << { 'key' => 'industry', 'dropdown' => { 'value' => '../food' } }
    row = accept
    assert_raises(Growth::PaymentSignature::Invalid) { fulfill(row) }
    assert_nil opening_request(row).account_id
  end

  def test_setup_stops_at_fixed_limit_and_cannot_run_in_outer_transaction
    row = opening
    Account.transaction { assert_raises(Growth::OpeningAccess::Invalid) { setup_opening(row) } }
    assert_equal 0, row.reload.onboarding_attempts
    row.update!(onboarding_attempts: 48)
    setup_opening(row)
    assert_equal 'attention', row.reload.onboarding_state
    refute latest(row)
  end

  def test_ingress_disabled_still_recovers_accepted_setup_but_closed_notice_gate_never_sends
    row = opening
    ENV['TOYBACO_OPENING_INGRESS_ENABLED'] = 'false'
    setup_opening(row)
    called = false
    Growth::OpeningNotices.stub(:enabled?, false) do
      Growth::OpeningNotices.stub(:send_mail!, ->(*) { called = true }) { Growth::OpeningNotices.sweep }
    end
    refute called
    assert_equal ['ready', 'queued'], [row.reload.onboarding_state, latest(row).state]
  end

  def test_delivery_intent_is_committed_before_mail_and_success_is_only_attempted
    row = opening
    setup_opening(row)
    notice = latest(row)
    observed = []
    notices_enabled do
      Growth::OpeningNotices.stub(:send_mail!, lambda { |_account, owner|
        assert_equal row.owner_id, owner.id
        other_connection { |db| observed << db.exec_params('SELECT state FROM toybaco_opening_notices WHERE id=$1', [notice.id]).first['state'] }
      }) do
        2.times { Growth::OpeningNotices.deliver!(notice.reload) }
      end
    end
    assert_equal ['dispatching'], observed
    assert_equal 'attempted', notice.reload.state
    assert_raises(ActiveRecord::ReadOnlyRecord) { notice.update!(state: 'queued', attempted_at: nil, finished_at: nil) }
  end

  def test_smtp_unknown_is_retained_without_auto_retry_even_after_a_year
    row = opening
    setup_opening(row)
    notice = latest(row)
    calls = 0
    notices_enabled do
      Growth::OpeningNotices.stub(:send_mail!, ->(*) { calls += 1; raise IOError, 'fixture lost SMTP reply' }) do
        Growth::OpeningNotices.deliver!(notice)
        travel_to NOW + 1.year
        Growth::OpeningNotices.sweep
      end
    end
    assert_equal [1, 'uncertain'], [calls, notice.reload.state]
  end

  def test_successful_smtp_then_database_write_failure_is_uncertain_and_is_not_resent
    row = opening
    setup_opening(row)
    notice = latest(row)
    original = notice.method(:update!)
    calls = 0
    notice.define_singleton_method(:update!) do |values|
      result = original.call(values)
      raise IOError if values[:state] == 'attempted'
      result
    end
    notices_enabled do
      Growth::OpeningNotices.stub(:send_mail!, ->(*) { calls += 1 }) { Growth::OpeningNotices.deliver!(notice) }
    end
    assert_equal [1, 'uncertain'], [calls, notice.reload.state]
  end

  def test_process_death_after_committed_intent_stays_dispatching_and_never_rearms_by_time
    row = opening
    setup_opening(row)
    notice = latest(row)
    notices_enabled do
      Growth::OpeningNotices.stub(:dispatch!, ->(*) { raise Interrupt }) do
        assert_raises(Interrupt) { Growth::OpeningNotices.deliver!(notice) }
      end
      travel_to NOW + 1.year
      assert_raises(Growth::OpeningAccess::Invalid) { retry_notice(row, notice, acknowledge_unknown: true) }
      Growth::OpeningNotices.sweep
    end
    assert_equal 'dispatching', notice.reload.state
  end

  def test_retry_requires_current_owner_admin_explicit_unknown_ack_and_same_request_is_history
    row = opening
    setup_opening(row)
    notice = latest(row)
    notice.update!(state: 'dispatching', attempted_at: NOW)
    notice.update!(state: 'uncertain', finished_at: NOW)
    travel_to NOW + 601
    notices_enabled do
      assert_raises(Growth::OpeningAccess::Invalid) { retry_notice(row, notice) }
      id = SecureRandom.uuid
      args = { actor_id: row.owner_id, request_id: id, previous_id: notice.id, acknowledge_unknown: true }
      next_notice = Growth::OpeningNotices.retry!(row, **args)
      assert_equal next_notice.id, Growth::OpeningNotices.retry!(row, **args).id
      assert_raises(Growth::OpeningAccess::Invalid) { Growth::OpeningNotices.retry!(row, **args.merge(actor_id: row.owner_id + 1)) }
      member = AccountUser.find_by!(account_id: row.account_id, user_id: row.owner_id)
      member.update!(role: :agent)
      assert_raises(Growth::OpeningAccess::Invalid) { Growth::OpeningNotices.retry!(row, **args) }
    end
  end

  def test_cancelled_identity_or_deleted_store_does_not_send_or_recreate
    row = opening
    setup_opening(row)
    notice = latest(row)
    Account.find(row.account_id).destroy!
    notices_enabled do
      Growth::OpeningNotices.stub(:send_mail!, ->(*) { flunk 'deleted account delivery' }) { Growth::OpeningNotices.deliver!(notice) }
    end
    assert_equal 'cancelled', notice.reload.state
    assert Toybaco::OpeningRequest.exists?(row.id)
    assert Toybaco::OpeningNotice.exists?(notice.id)
  end

  def test_database_enforces_single_pending_notice_restrict_parent_and_terminal_times
    row = opening
    setup_opening(row)
    notice = latest(row)
    assert_raises(ActiveRecord::RecordNotUnique) { Growth::OpeningNotices.create!(row, SecureRandom.uuid, row.owner_id) }
    assert_raises(ActiveRecord::InvalidForeignKey) { Toybaco::OpeningRequest.where(id: row.id).delete_all }
    assert_raises(ActiveRecord::StatementInvalid) { Toybaco::OpeningNotice.where(id: notice.id).update_all(state: 'attempted') }
    table = Toybaco::DurableAcceptance::TABLE
    assert Account.connection.select_value("SELECT EXISTS (SELECT 1 FROM #{table} WHERE capability='opening-ingress-v1')")
    Toybaco::OpeningNotice.where(id: notice.id).delete_all
    assert Account.connection.select_value("SELECT EXISTS (SELECT 1 FROM #{table} WHERE capability='opening-ingress-v1')")
    assert_raises(ActiveRecord::StatementInvalid) do
      Account.connection.execute("DELETE FROM #{table} WHERE capability='opening-ingress-v1'")
    end
  end

  def test_current_user_lock_prevents_identity_change_during_smtp
    row = opening
    setup_opening(row)
    notices_enabled do
      Growth::OpeningNotices.stub(:send_mail!, lambda { |_, owner|
        other_connection do |db|
          db.exec('BEGIN')
          assert_raises(PG::LockNotAvailable) { db.exec_params('SELECT id FROM users WHERE id=$1 FOR UPDATE NOWAIT', [owner.id]) }
          db.exec('ROLLBACK')
        end
      }) { Growth::OpeningNotices.deliver!(latest(row)) }
    end
    assert_equal 'attempted', latest(row).state
  end

  def test_current_contract_stopped_or_coverage_expired_cannot_initialize_an_inbox
    row = opening
    account = Account.find(row.account_id)
    original = account.internal_attributes.deep_dup
    account.update!(internal_attributes: original.merge('toybaco_subscription_status' => 'canceled'))
    assert_raises(Growth::OpeningAccess::Invalid) { setup_opening(row) }
    assert_empty account.inboxes
    travel_to NOW + 31
    expired = original.deep_dup
    expired['toybaco_growth_paid_period']['term_end'] = NOW.to_i
    account.update!(internal_attributes: expired)
    assert_raises(Growth::OpeningAccess::Invalid) { setup_opening(row) }
    assert_empty account.inboxes
  end

  def test_retry_daily_limit_and_stale_previous_receipt_do_not_create_extra_attempts
    row = opening
    setup_opening(row)
    initial = latest(row)
    notices_enabled do
      3.times do |index|
        notice = latest(row)
        notice.update!(state: 'dispatching', attempted_at: Time.now.utc)
        notice.update!(state: 'attempted', finished_at: Time.now.utc)
        travel_to NOW + (index + 1).hours
        if index < 2
          retry_notice(row, notice)
        else
          assert_raises(Growth::OpeningAccess::Invalid) { retry_notice(row, notice) }
        end
      end
      assert_raises(Growth::OpeningAccess::Invalid) { retry_notice(row, initial) }
    end
    assert_equal 3, Toybaco::OpeningNotice.where(opening_request_id: row.id).count
  end

  def test_real_mailer_local_capture_uses_static_login_and_reset_routes_without_reset_token
    row = opening
    setup_opening(row)
    settings = ENV.to_h.slice('FRONTEND_URL', 'MAILER_SENDER_EMAIL')
    previous = [ActionMailer::Base.delivery_method, ActionMailer::Base.perform_deliveries, ActionMailer::Base.raise_delivery_errors]
    ENV.update('FRONTEND_URL' => 'https://app.staging.toybaco.jp', 'MAILER_SENDER_EMAIL' => 'fixture@example.invalid')
    ActionMailer::Base.delivery_method = :test
    ActionMailer::Base.perform_deliveries = true
    ActionMailer::Base.raise_delivery_errors = true
    ActionMailer::Base.deliveries.clear
    notices_enabled { Growth::OpeningNotices.deliver!(latest(row)) }
    assert_equal 'attempted', latest(row).state
    mail = ActionMailer::Base.deliveries.last
    assert_equal [@email], mail.to
    assert_includes mail.body.decoded, 'https://app.staging.toybaco.jp/app/auth/reset/password'
    refute_includes mail.body.decoded, 'reset_password_token'
    refute_includes latest(row).attributes.to_json, @email
    assert_equal 1, ActionMailer::Base.deliveries.size
  ensure
    %w[FRONTEND_URL MAILER_SENDER_EMAIL].each { |key| settings&.key?(key) ? ENV[key] = settings[key] : ENV.delete(key) }
    if previous
      ActionMailer::Base.delivery_method, ActionMailer::Base.perform_deliveries, ActionMailer::Base.raise_delivery_errors = previous
      ActionMailer::Base.deliveries.clear
    end
  end

  def other_connection
    require 'pg'
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    db = PG.connect(host: config[:host], port: config[:port], dbname: config[:database], user: config[:username], password: config[:password])
    yield db
  ensure
    db&.finish
  end
end
