# frozen_string_literal: true

require 'rails_helper'
require 'stringio'

# FilterLogEvents の FilterPattern は `toybaco-fixture-<token>`。
# SES ingress の 204（Ingresses::Ses::InboundEmails#create）と同じ1行に
# mailbox=SupportMailbox と Conversation= が無いと診断は no のまま。
RSpec.describe Toybaco::InboundEmail do
  let(:token) { 'cafef00d' }
  let(:destination) { 'shop-1@inbox.staging.toybaco.jp' }
  let(:fixture_source) do
    [
      'From: Fixture Sender <fixture-sender@example.invalid>',
      "To: #{destination}",
      "Delivered-To: #{destination}",
      "X-Original-To: #{destination}",
      'Subject: toybaco inbound fixture',
      'Message-ID: <rewritten@unknown.host>',
      "X-Toybaco-Fixture: toybaco-fixture-#{token}",
      'MIME-Version: 1.0',
      'Content-Type: text/plain; charset=UTF-8',
      '',
      'fixture'
    ].join("\r\n")
  end

  def filter_pattern_line?(text)
    line = text.to_s
    line.include?('toybaco-route-log') &&
      line.include?("toybaco-fixture-#{token}") &&
      line.include?('mailbox=SupportMailbox') &&
      line.match?(/Conversation=(yes|no)/) &&
      line.exclude?("\n")
  end

  it 'ingress の原本から mailbox=SupportMailbox と Conversation と token を同じ行へ出す' do
    line = described_class.log_ingress_mailbox_route(fixture_source, channel_found: true)

    expect(filter_pattern_line?(line)).to be(true)
    expect(line).not_to match(/conversation_id=\d+/)
    expect(line).not_to include('fixture-sender')
  end

  it 'SES create 204 相当は FilterPattern と同じ token を mailbox と同じ行へ STDOUT に出す' do
    line = nil
    expect do
      line = described_class.log_ses_create_route(source: fixture_source)
    end.to output(a_string_including("toybaco-fixture-#{token}")
      .and(a_string_including('mailbox=SupportMailbox'))
      .and(a_string_matching(/Conversation=(yes|no)/))).to_stdout

    expect(filter_pattern_line?(line)).to be(true)
  end

  it 'SES InboundEmails#create の 204 ensure が FilterPattern と同じ1行を出す' do
    controller = Class.new do
      prepend Toybaco::InboundEmail::RoutingHooks::SesCreateRouteLog

      attr_accessor :status_code, :raw_source

      def initialize(raw_source)
        @raw_source = raw_source
        @status_code = 204
      end

      def create
        @status_code = 204
      end

      def response
        Struct.new(:status).new(status_code)
      end

      def notification
        Struct.new(:message_content).new(raw_source)
      end

      def request
        Struct.new(:raw_post).new(raw_source)
      end
    end.new(fixture_source)

    expect { controller.create }.to output(
      a_string_including('toybaco-route-log')
        .and(a_string_including("toybaco-fixture-#{token}"))
        .and(a_string_including('mailbox=SupportMailbox'))
        .and(a_string_matching(/Conversation=(yes|no)/))
    ).to_stdout
  end

  it 'SES path middleware は gem コントローラ 204 でも FilterPattern と同じ1行を出す' do
    app = ->(_env) { [204, {}, []] }
    middleware = Toybaco::InboundEmail::SesInboundRouteMiddleware.new(app)
    env = {
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO' => Toybaco::InboundEmail::INGRESS_PATH,
      'rack.input' => StringIO.new(fixture_source)
    }

    expect { middleware.call(env) }.to output(
      a_string_including('toybaco-route-log')
        .and(a_string_including("toybaco-fixture-#{token}"))
        .and(a_string_including('mailbox=SupportMailbox'))
        .and(a_string_matching(/Conversation=(yes|no)/))
    ).to_stdout
  end

  it 'SES path middleware は Engine の SCRIPT_NAME 分割でも 204 行を出す' do
    app = ->(_env) { [204, {}, []] }
    middleware = Toybaco::InboundEmail::SesInboundRouteMiddleware.new(app)
    env = {
      'REQUEST_METHOD' => 'POST',
      'SCRIPT_NAME' => Toybaco::InboundEmail::INGRESS_SCOPE,
      'PATH_INFO' => Toybaco::InboundEmail::INGRESS_ROUTE_PATH,
      'HTTP_X_TOYBACO_FIXTURE' => "toybaco-fixture-#{token}",
      'rack.input' => StringIO.new('')
    }

    expect { middleware.call(env) }.to output(
      a_string_including('toybaco-route-log')
        .and(a_string_including("toybaco-fixture-#{token}"))
        .and(a_string_matching(/Conversation=(yes|no)/))
    ).to_stdout
  end

  it 'live RouteSet が gem コントローラなら toybaco-ses-route-mismatch を ERROR する' do
    routes = Object.new
    def routes.recognize_path(_path, *)
      { controller: 'action_mailbox/ingresses/ses/inbound_emails', action: 'create' }
    end

    expect do
      line = described_class.warn_unless_ses_route_is_ours!(routes)
      expect(line).to include('toybaco-ses-route-mismatch')
      expect(line).to include('action_mailbox/ingresses/ses/inbound_emails')
    end.to output(a_string_including('toybaco-ses-route-mismatch')).to_stdout
  end

  it 'gem コントローラ 204 の process_action が ActionController.logger に route-log を出す' do
    described_class.install_ses_process_action_subscriber!
    messages = []
    logger = ActionController::Base.logger
    allow(logger).to receive(:info).and_wrap_original do |method, *args|
      messages << args.first.to_s
      method.call(*args)
    end

    ActiveSupport::Notifications.instrument(
      'process_action.action_controller',
      controller: 'ses/inbound_emails',
      action: 'create',
      status: 204,
      path: '/ses/inbound_emails',
      params: { 'Message' => fixture_source },
      headers: {}
    )

    expect(messages.any? { |text| filter_pattern_line?(text) }).to be(true)
  end

  it 'ActionMailbox::RoutingJob#perform の ensure が FilterPattern と同じ1行を出す' do
    job = Class.new do
      prepend Toybaco::InboundEmail::RoutingHooks::RoutingJobRouteLog

      def perform(_inbound_email)
        true
      end
    end.new
    inbound = Struct.new(:source).new(fixture_source)

    expect { job.perform(inbound) }.to output(
      a_string_including('toybaco-route-log')
        .and(a_string_including("toybaco-fixture-#{token}"))
        .and(a_string_including('mailbox=SupportMailbox'))
        .and(a_string_matching(/Conversation=(yes|no)/))
    ).to_stdout
  end
end
