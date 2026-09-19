# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require Rails.root.join('lib/toybaco/growth/trial_notice_delivery')
require Rails.root.join('lib/toybaco/growth/trial_state')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoGrowthTrialNoticesRuntimeTest < ActiveSupport::TestCase
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true
  Growth = Toybaco::Growth
  NOW = Time.utc(2026, 9, 19, 2)

  def setup
    travel_to NOW
    @old_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @account = create(:account, name: '<script>テスト店舗</script>')
    @owner = create(:user, :administrator, account: @account)
    @account.update!(internal_attributes: { Toybaco::BillingAccess::OWNER_KEY => @owner.id })
    terms = Toybaco::PlanCatalog.default.definition('free', '2026-09-18.1')
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: nil))
    @trial = Toybaco::GrowthTrial.create!(account_id: @account.id, facts_revision: 'a' * 64, example_id: 1, starts_at: NOW, ends_at: NOW + 14.days)
    @grant = Growth::AiGrants.new(@account).issue!(source: 'trial', source_key: "trial:#{@trial.id}", units: 100, starts_at: NOW, ends_at: @trial.ends_at)
  end

  def teardown
    travel_back
    ActiveJob::Base.queue_adapter = @old_adapter
    Current.reset
  end

  def notices
    Toybaco::GrowthTrialNotice.where(account_id: @account.id)
  end

  def issue
    Growth::TrialLifecycle.new(@account).refresh!
  end

  def deliver(notice, mail)
    Growth::TrialNoticeDelivery.stub(:enabled?, true) do
      Toybaco::GrowthTrialMailer.stub(:reminder, mail) { Toybaco::GrowthTrialNoticeJob.perform_now(notice.id) }
    end
  end

  def test_thresholds_create_each_notice_once_without_spending_any_ai_allowance
    issue
    assert_empty notices
    @grant.update!(used: 79)
    issue
    assert_empty notices
    @grant.update!(used: 80)
    2.times { issue }
    assert_equal ['remaining'], notices.pluck(:kind)
    assert_equal @owner.id, notices.first.user_id
    travel_to NOW + 11.days
    2.times { Toybaco::GrowthTrialSweepJob.perform_now }
    assert_equal %w[deadline remaining], notices.pluck(:kind).sort
    assert_equal 80, @grant.reload.used
    assert_equal %w[deadline remaining], Growth::TrialState.new(@account).read.fetch('notices').sort
  end

  def test_expired_or_upgraded_trial_does_not_issue_a_sales_notice
    travel_to NOW + 14.days
    issue
    assert_empty notices
    assert_equal 'expired', @trial.reload.completion_reason
  end

  def test_an_unconfirmed_or_departed_owner_is_not_notified
    @grant.update!(used: 80)
    @owner.update!(confirmed_at: nil)
    issue
    assert_empty notices
    @owner.update!(confirmed_at: NOW)
    @account.account_users.find_by!(user_id: @owner.id).destroy!
    issue
    assert_empty notices
  end

  def test_dispatch_records_before_sending_and_job_replays_never_send_twice
    @grant.update!(used: 80)
    issue
    notice = notices.first
    count = 0
    mail = Object.new
    mail.define_singleton_method(:deliver_now) { count += 1 }
    2.times { deliver(notice, mail) }
    assert_equal 1, count
    assert_equal 'attempted', notice.reload.state
    assert_equal NOW, notice.attempted_at
  end

  def test_unknown_delivery_result_is_not_retried
    @grant.update!(used: 80)
    issue
    notice = notices.first
    count = 0
    mail = Object.new
    mail.define_singleton_method(:deliver_now) { count += 1; raise Timeout::Error, 'fixture uncertainty' }
    2.times { deliver(notice, mail) }
    assert_equal 1, count
    assert_equal 'uncertain', notice.reload.state
  end

  def test_queued_mail_is_cancelled_after_owner_removal_or_trial_end
    @grant.update!(used: 80)
    issue
    notice = notices.first
    @account.account_users.find_by!(user_id: @owner.id).destroy!
    deliver(notice, nil)
    assert_equal 'cancelled', notice.reload.state
    @owner = create(:user, :administrator, account: @account)
    @account.update!(internal_attributes: @account.internal_attributes.merge(Toybaco::BillingAccess::OWNER_KEY => @owner.id))
    travel_to NOW + 11.days
    issue
    deadline = notices.find_by!(kind: 'deadline')
    travel_to NOW + 14.days
    deliver(deadline, nil)
    assert_equal 'cancelled', deadline.reload.state
  end

  def test_notice_mail_has_only_the_confirmed_owner_and_escaped_store_name
    @grant.update!(used: 80)
    issue
    previous = ENV.to_h.slice('FRONTEND_URL', 'MAILER_SENDER_EMAIL')
    ENV['FRONTEND_URL'] = 'https://app.staging.toybaco.jp'
    ENV['MAILER_SENDER_EMAIL'] = 'トイバコ <no-reply@toybaco.jp>'
    mail = Toybaco::GrowthTrialMailer.reminder(notices.first).message
    assert_equal [@owner.email], mail.to
    assert_includes mail.subject, '残り20回以内'
    assert_includes mail.text_part.body.decoded, '自動課金はありません'
    assert_includes mail.html_part.body.decoded, '&lt;script&gt;'
    refute_includes mail.html_part.body.decoded, '<script>'
    assert_includes mail.html_part.body.decoded, "account_id=#{@account.id}"
  ensure
    %w[FRONTEND_URL MAILER_SENDER_EMAIL].each { |name| previous&.key?(name) ? ENV[name] = previous[name] : ENV.delete(name) }
  end

  def test_delivery_is_parked_until_notifications_are_enabled
    @grant.update!(used: 80)
    issue
    Growth::TrialNoticeDelivery.stub(:enabled?, false) { Toybaco::GrowthTrialNoticeJob.perform_now(notices.first.id) }
    assert_equal 'queued', notices.first.reload.state
  end

  def test_extended_deadline_defers_an_unsent_notice_without_duplicate_creation
    travel_to NOW + 11.days
    issue
    notice = notices.first
    @trial.update!(ends_at: @trial.ends_at + 1.day)
    deliver(notice, nil)
    assert_equal 'queued', notice.reload.state
    travel_to NOW + 12.days
    issue
    assert_equal [notice.id], notices.pluck(:id)
    count = 0
    mail = Object.new
    mail.define_singleton_method(:deliver_now) { count += 1 }
    deliver(notice, mail)
    assert_equal 1, count
  end
end
