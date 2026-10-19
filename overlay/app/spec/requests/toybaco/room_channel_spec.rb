# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RoomChannel, type: :channel do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:credentials) { user.create_new_auth_token }
  let(:cable_env) do
    Rack::MockRequest.env_for('https://app.example.test/cable', 'HTTP_ORIGIN' => 'https://app.example.test',
                                                                'HTTP_COOKIE' => "cw_d_session_info=#{Rack::Utils.escape(credentials.to_json)}")
  end

  before do
    stub_connection(env: cable_env)
    connection.define_singleton_method(:close) { |**_options| nil }
  end

  it 'subscribes a logged-in user and closes the socket after server revocation' do
    subscribe(user_id: user.id, account_id: account.id, pubsub_token: user.pubsub_token)
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from("account_#{account.id}")
    user.update!(tokens: {})
    expect(connection).to receive(:close).with(reconnect: false)
    expect(subscription.send(:verify_toybaco_session)).to be(false)
    expect(subscription.send(:streams)).to be_empty
  end

  it 'rejects a user subscription with only the long-lived pubsub identifier' do
    cable_env.delete('HTTP_COOKIE')
    subscribe(user_id: user.id, account_id: account.id, pubsub_token: user.pubsub_token)
    expect(subscription).to be_rejected
    expect(subscription.send(:streams)).to be_empty
  end

  it 'keeps the public contact widget on its separate contact-inbox boundary' do
    widget = Channel::WebWidget.create!(account: account, website_url: 'https://customer.example.test')
    inbox = Inbox.create!(account: account, channel: widget, name: 'Synthetic widget')
    contact_inbox = create(:contact_inbox, inbox: inbox, contact: create(:contact, account: account))
    subscribe(pubsub_token: contact_inbox.pubsub_token)
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from(contact_inbox.pubsub_token)
    expect(subscription.send(:verify_toybaco_session)).to be(true)
    Toybaco::Security::WidgetSession.revoke(contact_inbox, source_id: contact_inbox.source_id)
    expect(connection).to receive(:close).with(reconnect: false)
    expect(subscription.send(:verify_toybaco_session)).to be(false)
    expect(subscription.send(:streams)).to be_empty
  end

  # 上の例の stub_connection(ActionCable の ConnectionStub、Rails 7.2.3.2 channel/test_case.rb 50-61 行)は渡した識別子を
  # public な singleton method にするだけで、実 Connection の可視性を再現しない(以前は public な request を渡していたため、
  # channel の connection.request の欠陥を見逃した)。
  # 本番の ApplicationCable::Connection では ActionCable::Connection::Base#request が private なので、
  # ここでは実 Connection を Rack env から作り、同じ subscribe 経路を通す(channel が request を呼べば NoMethodError)。
  context 'with the real ApplicationCable::Connection whose #request is private' do
    let(:base_url) { 'https://app.example.test' }
    let(:session_cookie) { "cw_d_session_info=#{Rack::Utils.escape(credentials.to_json)}" }

    def connect_real_cable(cookie: nil, origin: base_url)
      env = Rack::MockRequest.env_for("#{base_url}/cable", 'HTTP_ORIGIN' => origin)
      env['HTTP_COOKIE'] = cookie if cookie
      @connection = ApplicationCable::Connection.new(ActionCable.server, env)
    end

    def http_widget_session
      widget = Channel::WebWidget.create!(account: account, website_url: 'https://customer.example.test')
      Inbox.create!(account: account, channel: widget, name: 'Synthetic widget')
      contact_inbox = create(:contact_inbox, inbox: widget.inbox, contact: create(:contact, account: account))
      secret = SecureRandom.hex(32)
      row = Toybaco::WidgetSessionRecord.create!(
        contact_inbox: contact_inbox, inbox_id: contact_inbox.inbox_id,
        secret_digest: Toybaco::Security::WidgetHttpSession.digest(secret),
        link_digest: Toybaco::Security::WidgetHttpSession.link_digest(contact_inbox), bootstrap_digest: SecureRandom.hex(32),
        bootstrap_expires_at: 1.minute.from_now, rotated_at: Time.current, expires_at: 30.days.from_now
      )
      { contact_inbox: contact_inbox, cookie: "#{Toybaco::Security::WidgetHttpSession.cookie_name(widget)}=#{row.id}.#{secret}",
        pubsub_token: "tbwhttp1.#{widget.website_token}.#{Toybaco::Security::WidgetHttpSession.new(row).proof}" }
    end

    # oracle は framework の private request と同じ式(Rails 7.2.3.2 connection/base.rb 178-183 行)で同じ env から作る。
    def framework_request
      ActionDispatch::Request.new(Rails.application.env_config.merge(connection.env))
    end

    def request_fingerprint(request)
      { cookies: request.cookies, origin: request.headers['Origin'], base_url: request.base_url,
        request_id: request.request_id, env_config: request.env.slice(*Rails.application.env_config.keys) }
    end

    it 'keeps #request private and #env public on the framework connection used in production' do
      connect_real_cable
      expect(connection).to be_a(ApplicationCable::Connection)
      expect(connection).not_to respond_to(:request)
      expect(ActionCable::Connection::Base.private_method_defined?(:request)).to be(true)
      expect(connection).to respond_to(:env)
      expect { connection.request }.to raise_error(NoMethodError, /private method .request. called/)
    end

    it 'subscribes a dashboard user from the session cookie and closes the socket after server revocation' do
      connect_real_cable(cookie: session_cookie)
      subscribe(user_id: user.id, account_id: account.id, pubsub_token: user.pubsub_token)
      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_from("account_#{account.id}")
      user.update!(tokens: {})
      expect(connection).to receive(:close).with(reconnect: false)
      expect(subscription.send(:verify_toybaco_session)).to be(false)
      expect(subscription.send(:streams)).to be_empty
    end

    it 'still rejects the dashboard session cookie from a foreign origin' do
      connect_real_cable(cookie: session_cookie, origin: 'https://foreign.example.test')
      subscribe(user_id: user.id, account_id: account.id, pubsub_token: user.pubsub_token)
      expect(subscription).to be_rejected
      expect(subscription.send(:streams)).to be_empty
    end

    it 'subscribes the http-session widget contact from the __Host cookie and the proof' do
      session = http_widget_session
      connect_real_cable(cookie: session[:cookie])
      subscribe(pubsub_token: session[:pubsub_token])
      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_from(session[:contact_inbox].pubsub_token)
      expect(subscription.send(:current_user)).to eq(session[:contact_inbox].contact)
      expect(subscription.send(:verify_toybaco_session)).to be(true)
    end

    it 'still rejects the http-session widget proof without its cookie' do
      session = http_widget_session
      connect_real_cable
      subscribe(pubsub_token: session[:pubsub_token])
      expect(subscription).to be_rejected
      expect(subscription.send(:streams)).to be_empty
    end

    it 'builds the dashboard user request from the connection env exactly like the framework request' do
      connect_real_cable(cookie: session_cookie)
      subscribe(user_id: user.id, account_id: account.id, pubsub_token: user.pubsub_token)
      expect(subscription).to be_confirmed
      built = request_fingerprint(subscription.send(:toybaco_cable_request))
      expect(built[:cookies]).to include('cw_d_session_info')
      expect(built[:env_config]).not_to be_empty
      expect(built).to eq(request_fingerprint(framework_request))
    end

    it 'builds the http-session widget request from the connection env exactly like the framework request' do
      session = http_widget_session
      connect_real_cable(cookie: session[:cookie])
      subscribe(pubsub_token: session[:pubsub_token])
      expect(subscription).to be_confirmed
      built = request_fingerprint(subscription.send(:toybaco_cable_request))
      expect(built[:cookies]).to include(session[:cookie].split('=', 2).first)
      expect(built[:env_config]).not_to be_empty
      expect(built).to eq(request_fingerprint(framework_request))
    end
  end
end
