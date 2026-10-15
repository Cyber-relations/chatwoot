# frozen_string_literal: true

require 'rails/test_help'

# The Ruby quality image has no compiled widget manifest. Asset delivery is
# checked by the production-image build and staging UI; these tests exercise
# the real widget callbacks, identity selection and rendered auth token only.
module ToybacoWidgetBindingAssetTestHelper
  def vite_client_tag(*)
    ''
  end

  def vite_javascript_tag(*)
    ''
  end
end

WidgetsController._helpers.prepend(ToybacoWidgetBindingAssetTestHelper)

class ToybacoWidgetInboxBindingRuntimeTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = true

  def setup
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    host! 'www.example.com'
    https!
    accounts = 2.times.map { |index| Account.create!(name: "Synthetic widget account #{index}") }
    @widgets = [accounts[0], accounts[0], accounts[1]].map do |account|
      widget = Channel::WebWidget.create!(account: account, website_url: 'https://customer.example.test')
      Inbox.create!(account: account, channel: widget, name: 'Synthetic widget')
      widget
    end
    source_id = SecureRandom.uuid
    @links = @widgets.map do |widget|
      contact = Contact.create!(account: widget.account, name: 'Synthetic visitor')
      ContactInbox.create!(contact: contact, inbox: widget.inbox, source_id: source_id)
    end
    @tokens = @links.map do |link|
      Widget::TokenService.new(payload: { inbox_id: link.inbox_id, source_id: link.source_id }).generate_token
    end
  end

  def teardown
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  def test_same_widget_contact_read_and_update_preserve_existing_token
    get_contact(@widgets[0], @tokens[0])
    assert_response :success
    assert_equal @links[0].contact_id, response.parsed_body.fetch('id')

    patch '/api/v1/widget/contact', params: { website_token: @widgets[0].website_token, name: 'Own visitor update' },
                                    headers: { 'X-Auth-Token' => @tokens[0] }, as: :json
    assert_response :success
    assert_equal 'Own visitor update', @links[0].contact.reload.name
  end

  def test_signed_token_cannot_read_another_inbox_with_colliding_source_id
    [@widgets[1], @widgets[2]].each do |widget|
      get_contact(widget, @tokens[0])
      assert_response :not_found
    end
    get_contact(@widgets[0], @tokens[2])
    assert_response :not_found
  end

  def test_signed_token_cannot_update_another_account_with_colliding_source_id
    previous = @links[2].contact.name
    patch '/api/v1/widget/contact', params: { website_token: @widgets[2].website_token, name: 'Foreign visitor update' },
                                    headers: { 'X-Auth-Token' => @tokens[0] }, as: :json
    assert_response :not_found
    assert_equal previous, @links[2].contact.reload.name
  end

  def test_signed_token_without_inbox_claim_cannot_access_contact
    token = Widget::TokenService.new(payload: { source_id: @links[0].source_id }).generate_token
    get_contact(@widgets[0], token)
    assert_response :not_found
  end

  def test_widget_render_preserves_own_token_and_contact
    get '/widget', params: { website_token: @widgets[0].website_token, cw_conversation: @tokens[0] }
    assert_response :success
    assert_equal @tokens[0], rendered_token
    assert_credential_response_protected
  end

  def test_new_widget_visitor_response_is_not_cacheable_or_a_referrer
    get '/widget', params: { website_token: @widgets[0].website_token }
    assert_response :success
    assert_credential_response_protected
    claims = Widget::TokenService.new(token: rendered_token).decode_token
    assert_equal @widgets[0].inbox.id, claims.fetch(:inbox_id)
  end

  def test_widget_frame_ancestor_policy_is_preserved
    @widgets[0].update!(allowed_domains: 'https://customer.example.test')
    get '/widget', params: { website_token: @widgets[0].website_token, cw_conversation: @tokens[0] }
    assert_response :success
    assert_credential_response_protected
    assert_equal 'frame-ancestors https://customer.example.test', response.headers['Content-Security-Policy']
    assert_equal @tokens[0], rendered_token
  end

  def test_widget_render_starts_separate_visitor_for_foreign_inbox_token
    [@widgets[1], @widgets[2]].each do |widget|
      get '/widget', params: { website_token: widget.website_token, cw_conversation: @tokens[0] }
      assert_response :success
      token = rendered_token
      refute_equal @tokens[0], token
      claims = Widget::TokenService.new(token: token).decode_token
      assert_equal widget.inbox.id, claims.fetch(:inbox_id)
      refute_equal @links[0].source_id, claims.fetch(:source_id)
      get_contact(widget, token)
      assert_response :success
      refute_equal @links[@widgets.index(widget)].contact_id, response.parsed_body.fetch('id')
    end
  end

  def test_widget_config_renewal_preserves_own_contact
    post_config(@widgets[0], @tokens[0])
    assert_response :success
    assert_equal @links[0].contact_id, response.parsed_body.dig('contact', 'id')
    claims = Widget::TokenService.new(token: config_token).decode_token
    assert_equal @widgets[0].inbox.id, claims.fetch(:inbox_id)
    assert_equal @links[0].source_id, claims.fetch(:source_id)
    assert_credential_response_protected
  end

  def test_widget_config_foreign_inbox_token_starts_separate_visitor
    [@widgets[1], @widgets[2]].each do |widget|
      post_config(widget, @tokens[0])
      assert_response :success
      refute_equal @links[@widgets.index(widget)].contact_id, response.parsed_body.dig('contact', 'id')
      claims = Widget::TokenService.new(token: config_token).decode_token
      assert_equal widget.inbox.id, claims.fetch(:inbox_id)
      refute_equal @links[0].source_id, claims.fetch(:source_id)
    end
  end

  def test_widget_config_without_inbox_claim_starts_separate_visitor
    token = Widget::TokenService.new(payload: { source_id: @links[0].source_id }).generate_token
    post_config(@widgets[0], token)
    assert_response :success
    refute_equal @links[0].contact_id, response.parsed_body.dig('contact', 'id')
    claims = Widget::TokenService.new(token: config_token).decode_token
    assert_equal @widgets[0].inbox.id, claims.fetch(:inbox_id)
    refute_equal @links[0].source_id, claims.fetch(:source_id)
  end

  def test_widget_config_without_token_starts_separate_visitor
    post_config(@widgets[0], nil)
    assert_response :success
    refute_equal @links[0].contact_id, response.parsed_body.dig('contact', 'id')
    claims = Widget::TokenService.new(token: config_token).decode_token
    assert_equal @widgets[0].inbox.id, claims.fetch(:inbox_id)
    refute_equal @links[0].source_id, claims.fetch(:source_id)
    assert_credential_response_protected
  end

  def test_explicit_reset_revokes_only_own_link_and_preserves_history
    link = @links[0]
    old_source = link.source_id
    old_stream = link.pubsub_token
    history = Conversation.create!(account: link.inbox.account, inbox: link.inbox, contact: link.contact, contact_inbox: link)
    session = Toybaco::Security::WidgetSession.new(link)
    foreign = @links.drop(1).map { |other| other.attributes.slice('source_id', 'pubsub_token') }

    delete_session(@widgets[0], @tokens[0])
    assert_response :success
    assert_equal true, response.parsed_body.fetch('session_revoked')
    assert_credential_response_protected
    refute_equal old_source, link.reload.source_id
    refute_equal old_stream, link.pubsub_token
    assert_nil ContactInbox.find_by(pubsub_token: old_stream)
    refute session.current?
    assert Toybaco::Security::WidgetSession.new(link).current?
    assert_equal link.id, history.reload.contact_inbox_id
    assert_equal link.contact_id, history.contact_id
    assert_equal foreign, @links.drop(1).map { |other| other.reload.attributes.slice('source_id', 'pubsub_token') }
    get_contact(@widgets[0], @tokens[0])
    assert_response :not_found

    rotated = link.attributes.slice('source_id', 'pubsub_token')
    delete_session(@widgets[0], @tokens[0])
    assert_response :success
    assert_equal true, response.parsed_body.fetch('session_revoked')
    assert_equal rotated, link.reload.attributes.slice('source_id', 'pubsub_token'), 'Stale retry must not rotate another session'
  end

  def test_reset_rejects_another_inbox_or_account_even_with_colliding_source
    before = @links.map { |link| link.attributes.slice('source_id', 'pubsub_token') }
    [@widgets[1], @widgets[2]].each do |widget|
      delete_session(widget, @tokens[0])
      assert_response :not_found
    end
    assert_equal before, @links.map { |link| link.reload.attributes.slice('source_id', 'pubsub_token') }
  end

  def test_invalid_or_expired_reset_is_an_idempotent_noop
    before = @links.map { |link| link.attributes.slice('source_id', 'pubsub_token') }
    expired = JWT.encode({ inbox_id: @links[0].inbox_id, source_id: @links[0].source_id, exp: 1 }, Rails.application.secret_key_base, 'HS256')
    [nil, 'synthetic-invalid-token', expired].each do |token|
      delete_session(@widgets[0], token)
      assert_response :success
      assert_equal true, response.parsed_body.fetch('session_revoked')
    end
    assert_equal before, @links.map { |link| link.reload.attributes.slice('source_id', 'pubsub_token') }
  end

  def test_legitimate_contact_merge_keeps_stream_and_history_until_explicit_reset
    link = @links[0]
    target = Contact.create!(account: link.contact.account, name: 'Synthetic merged visitor')
    history = Conversation.create!(account: link.inbox.account, inbox: link.inbox, contact: link.contact, contact_inbox: link)
    session = Toybaco::Security::WidgetSession.new(link)
    ContactMergeAction.new(account: link.inbox.account, base_contact: target, mergee_contact: link.contact).perform
    assert_equal target.id, link.reload.contact_id
    assert_equal link.id, history.reload.contact_inbox_id
    assert session.current?, 'A preserved ContactInbox is the identity boundary across a legitimate merge'
    get_contact(@widgets[0], @tokens[0])
    assert_response :success
    assert_equal target.id, response.parsed_body.fetch('id')
    delete_session(@widgets[0], @tokens[0])
    assert_response :success
    refute session.current?
    assert_equal target.id, history.reload.contact_id
  end

  private

  def delete_session(widget, token)
    headers = token ? { 'X-Auth-Token' => token } : {}
    delete '/api/v1/widget/session', params: { website_token: widget.website_token }, headers: headers, as: :json
  end

  def assert_credential_response_protected
    assert_includes response.headers.fetch('Cache-Control').split(',').map(&:strip), 'no-store'
    assert_includes response.headers.fetch('Cache-Control').split(',').map(&:strip), 'private'
    assert_equal 'no-referrer', response.headers['Referrer-Policy']
  end

  def get_contact(widget, token)
    get '/api/v1/widget/contact', params: { website_token: widget.website_token },
                                  headers: { 'X-Auth-Token' => token }, as: :json
  end

  def rendered_token
    response.body.match(/window\.authToken = '([^']+)'/).captures.first
  end

  def post_config(widget, token)
    headers = token ? { 'X-Auth-Token' => token } : {}
    post '/api/v1/widget/config', params: { website_token: widget.website_token }, headers: headers, as: :json
  end

  def config_token
    response.parsed_body.dig('website_channel_config', 'auth_token')
  end
end
