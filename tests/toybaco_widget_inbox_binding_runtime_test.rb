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
  end

  private

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
