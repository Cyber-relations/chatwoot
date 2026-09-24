# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require_relative 'toybaco_growth_purchase_stripe_fixture'
require_relative 'toybaco_opening_fixture'
require Rails.root.join('lib/toybaco/growth/opening_fulfillment')
require Rails.root.join('lib/toybaco/growth/opening_notices')

class ToybacoOpeningOnboardingHttpTest < ActionDispatch::IntegrationTest
  include ToybacoOpeningFixture
  self.use_transactional_tests = false
  Growth = Toybaco::Growth
  NOW = Time.utc(2026, 9, 24, 12)

  def ready_request
    event = accept
    fulfill(event)
    opening_request(event)
  end

  def as_user(user)
    Toybaco::Oidc::SessionReader.stub(:new, Struct.new(:user).new(user)) { yield }
  end

  def retry_post(row, notice, id: SecureRandom.uuid, origin: 'http://www.example.com', unknown: false)
    post '/toybaco/opening/retry_notice',
         params: { account_id: row.account_id, request_id: id, previous_id: notice.id, acknowledge_unknown: unknown }.to_json,
         headers: { 'CONTENT_TYPE' => 'application/json', 'Origin' => origin, 'Sec-Fetch-Site' => 'same-origin' }
  end

  def test_anonymous_foreign_account_and_demoted_owner_cannot_read_or_retry
    row = ready_request
    as_user(nil) { get '/toybaco/opening/state', params: { account_id: row.account_id } }
    assert_response :unauthorized
    owner = User.find(row.owner_id)
    as_user(owner) do
      get '/toybaco/opening/state', params: { account_id: row.account_id + 999 }
      assert_response :forbidden
      AccountUser.find_by!(account_id: row.account_id, user_id: row.owner_id).update!(role: :agent)
      get '/toybaco/opening/state', params: { account_id: row.account_id }
      assert_response :conflict
    end
  end

  def test_cross_origin_disabled_notices_and_dispatching_attempt_never_queue_retry
    row = ready_request
    notice = Growth::OpeningNotices.create!(row, 'initial', row.owner_id)
    notice.update!(state: 'dispatching', attempted_at: NOW)
    as_user(User.find(row.owner_id)) do
      Growth::OpeningNotices.stub(:enabled?, true) do
        retry_post(row, notice, origin: 'https://foreign.invalid')
        assert_response :forbidden
        retry_post(row, notice, unknown: true)
        assert_response :conflict
      end
      Growth::OpeningNotices.stub(:enabled?, false) do
        retry_post(row, notice)
        assert_response :conflict
      end
    end
    assert_equal 1, Toybaco::OpeningNotice.where(opening_request_id: row.id).count
  end

  def test_explicit_owner_unknown_ack_creates_one_retry_and_replay_is_same_history
    row = ready_request
    notice = Growth::OpeningNotices.create!(row, 'initial', row.owner_id)
    notice.update!(state: 'dispatching', attempted_at: NOW)
    notice.update!(state: 'uncertain', finished_at: NOW)
    travel_to NOW + 601
    as_user(User.find(row.owner_id)) do
      Growth::OpeningNotices.stub(:enabled?, true) do
        retry_post(row, notice)
        assert_response :conflict
        id = SecureRandom.uuid
        retry_post(row, notice, id: id, unknown: true)
        assert_response :accepted
        accepted = response.parsed_body
        retry_post(row, notice, id: id, unknown: true)
        assert_response :accepted
        assert_equal accepted, response.parsed_body
        assert_equal 'queued', accepted['state']
      end
    end
    assert_equal 2, Toybaco::OpeningNotice.where(opening_request_id: row.id).count
  end

  def test_read_only_state_contains_no_recipient_token_or_stripe_identity
    row = ready_request
    Growth::OpeningNotices.create!(row, 'initial', row.owner_id)
    as_user(User.find(row.owner_id)) { get '/toybaco/opening/state', params: { account_id: row.account_id } }
    assert_response :ok
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal %w[inbox_state industry_state notice onboarding_state], response.parsed_body.keys.sort
    [@email, @session_id, @sub_id, 'reset_password_token'].each { |value| refute_includes response.body, value }
  end
end
