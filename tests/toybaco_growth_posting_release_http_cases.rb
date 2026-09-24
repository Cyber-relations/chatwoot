# frozen_string_literal: true

require Rails.root.join('lib/toybaco/growth/posting_authority')

module ToybacoPostingReleaseHttpCases
  def posting_endpoint
    "/toybaco/growth/posting-release?account_id=#{@account.id}"
  end

  def with_posting_release_fixture
    flags = %w[TOYBACO_POSTING_RELEASE_ENABLED TOYBACO_POSTING_AUTHORITY_ENABLED TOYBACO_POSTING_EXECUTION_ENABLED]
    previous = flags.to_h { |key| [key, ENV[key]] }
    flags.each { |key| ENV[key] = 'true' }
    @rows['posting_accounts'] = [
      { 'id' => 'channel-a', 'name' => '<script>private-name</script>', 'created_at_us' => 1 },
      { 'id' => 'channel-b', 'name' => '投稿先B', 'created_at_us' => 2 }
    ]
    prep = Struct.new(:calls) do
      def read = { 'revision' => 'b' * 64, 'limit' => 6, 'available_ids' => %w[channel-a channel-b], 'keep_ids' => [] }
      def prepare!(**input)
        calls << input
        { 'receipt' => { 'request_id' => input[:request_id], 'keep_ids' => input[:integration_ids] } }
      end
    end.new([])
    delivery = Struct.new(:calls) do
      def call(**input) = calls << input
    end.new([])
    authority = Struct.new(:calls, :failure, :current_failure) do
      def current
        raise current_failure if current_failure
         { 'current' => true, 'keep_ids' => ['channel-a'] }
      end
      def read(**) = { 'revision' => 'c' * 64 }
      def activate!(**input)
        raise failure if failure
        calls << input
        { 'authority_id' => input[:authority_id], 'state' => 'active', 'current' => true, 'execute' => false }
      end
    end.new([], nil)
    Toybaco::Checkout::Client.stub(:new, Object.new) do
      Toybaco::Growth::PostingPreparation.stub(:new, prep) do
        Toybaco::Growth::PostingPreparationDelivery.stub(:new, ->(*) { delivery }) do
          Toybaco::Growth::PostingAuthority.stub(:new, authority) { yield prep, delivery, authority }
        end
      end
    end
  ensure
    previous&.each { |key, value| ENV[key] = value }
  end

  def test_posting_release_real_owner_route_renders_escaped_selection_and_submits_explicit_choice
    with_posting_release_fixture do |prep, delivery, authority|
      authenticated do
        get posting_endpoint
        assert_response :success
        assert_select 'h1', '投稿先を再開'
        assert_select 'input[checked][disabled][value="channel-a"]', 1
        assert_includes response.body, '&lt;script&gt;private-name&lt;/script&gt;'
        refute_includes response.body, '<script>private-name</script>'
        assert_select 'script[type="module"][src]', 1
        assert_equal 'no-store', response.headers['Cache-Control']
        post posting_endpoint, params: { integration_ids: %w[channel-a channel-b], revision: 'b' * 64, request_id: 'd' * 64 },
                               as: :json, headers: { 'Origin' => 'http://app.example.com' }
        assert_response :success
        assert_equal %w[channel-a channel-b], response.parsed_body['keep_ids']
        assert_equal @account.id, response.parsed_body['account_id']
        refute response.parsed_body['execute']
        assert_equal 1, prep.calls.size
        assert_equal [{ request_id: 'd' * 64 }], delivery.calls
        assert_equal 1, authority.calls.size
        assert_equal 'd' * 64, authority.calls.first.fetch(:preparation_request_id)
        assert_equal 'c' * 64, authority.calls.first.fetch(:revision)
        assert_match(/\A[0-9a-f]{64}\z/, authority.calls.first.fetch(:authority_id))
      end
    end
  end

  def test_posting_release_real_route_rejects_unowned_store_unlogged_user_and_cross_origin
    with_posting_release_fixture do |prep, delivery, authority|
      authenticated(@staff) { get posting_endpoint; assert_response :forbidden }
      authenticated(nil) { get posting_endpoint; assert_response :unauthorized }
      authenticated do
        get "/toybaco/growth/posting-release?account_id=#{@foreign.account_id}"
        assert_response :forbidden
        post posting_endpoint, params: {}, as: :json, headers: { 'Origin' => 'https://foreign.invalid' }
        assert_response :forbidden
      end
      [prep, delivery, authority].each { |service| assert_empty service.calls }
    end
  end

  def test_posting_release_real_route_requires_every_feature_flag
    with_posting_release_fixture do |prep, delivery, authority|
      %w[TOYBACO_POSTING_RELEASE_ENABLED TOYBACO_POSTING_AUTHORITY_ENABLED TOYBACO_POSTING_EXECUTION_ENABLED].each do |key|
        ENV[key] = 'false'
        authenticated { get posting_endpoint; assert_response :not_found }
        ENV[key] = 'true'
      end
      [prep, delivery, authority].each { |service| assert_empty service.calls }
    end
  end

  def test_posting_release_real_route_does_not_claim_activation_on_conflict_or_leak_provider_error
    with_posting_release_fixture do |_prep, _delivery, authority|
      authority.failure = Toybaco::Growth::PostingPreparationRecord::Invalid.new('fixture-private-provider-data')
      authenticated do
        post posting_endpoint, params: { integration_ids: ['channel-b'], revision: 'b' * 64, request_id: 'd' * 64 },
                               as: :json, headers: { 'Origin' => 'http://app.example.com' }
        assert_response :conflict
        refute_includes response.body, 'fixture-private-provider-data'
        refute response.parsed_body.key?('current')
        assert_empty authority.calls
      end
    end
  end
  def test_posting_release_delivery_failure_never_reaches_activation_or_leaks_error
    with_posting_release_fixture do |prep, delivery, authority|
      delivery.define_singleton_method(:call) do |**input|
        calls << input
        raise Toybaco::Growth::PostingPreparationRecord::Invalid, 'fixture-private-delivery-data'
      end
      authenticated do
        post posting_endpoint, params: { integration_ids: ['channel-b'], revision: 'b' * 64, request_id: 'd' * 64 },
                               as: :json, headers: { 'Origin' => 'http://app.example.com' }
        assert_response :conflict
        refute_includes response.body, 'fixture-private-delivery-data'
        refute response.parsed_body.key?('current')
        assert_equal 1, prep.calls.size
        assert_equal [{ request_id: 'd' * 64 }], delivery.calls
        assert_empty authority.calls
      end
    end
  end

  def test_posting_release_expired_authority_can_show_fresh_explicit_confirmation_without_claiming_current
    with_posting_release_fixture do |_prep, _delivery, authority|
      authority.current_failure = Toybaco::Growth::PostingPreparationRecord::Invalid.new('expired fixture')
      authenticated do
        get posting_endpoint
        assert_response :success
        assert_select 'input[checked][disabled]', 0
        assert_includes response.body, '前回の再開状態を確認できませんでした'
        refute_includes response.body, 'expired fixture'
        assert_empty authority.calls
      end
    end
  end

end
