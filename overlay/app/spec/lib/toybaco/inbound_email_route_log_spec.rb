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

  it 'SES path middleware は token だけ残し toybaco-route-log を puts しない' do
    seen = nil
    app = lambda do |_env|
      seen = described_class.stored_ses_route_token
      [204, {}, []]
    end
    middleware = Toybaco::InboundEmail::SesInboundRouteMiddleware.new(app)
    env = {
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO' => Toybaco::InboundEmail::INGRESS_PATH,
      'rack.input' => StringIO.new(fixture_source)
    }

    expect { middleware.call(env) }.not_to output(a_string_including('toybaco-route-log')).to_stdout
    expect(seen).to include("toybaco-fixture-#{token}")
  end

  it 'SES path middleware は Engine の SCRIPT_NAME 分割でも token を残す' do
    seen = nil
    app = lambda do |_env|
      seen = described_class.stored_ses_route_token
      [204, {}, []]
    end
    middleware = Toybaco::InboundEmail::SesInboundRouteMiddleware.new(app)
    env = {
      'REQUEST_METHOD' => 'POST',
      'SCRIPT_NAME' => Toybaco::InboundEmail::INGRESS_SCOPE,
      'PATH_INFO' => Toybaco::InboundEmail::INGRESS_ROUTE_PATH,
      'HTTP_X_TOYBACO_FIXTURE' => "toybaco-fixture-#{token}",
      'rack.input' => StringIO.new('')
    }

    expect { middleware.call(env) }.not_to output(a_string_including('toybaco-route-log')).to_stdout
    expect(seen).to include("toybaco-fixture-#{token}")
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

  it 'LogSubscriber start_processing の Parameters と同じ logger に route-log を出す' do
    messages = []
    logger = instance_double(Logger)
    allow(logger).to receive(:info) do |msg = nil, &block|
      messages << (block ? block.call : msg).to_s
    end

    subscriber = Class.new do
      attr_reader :logger

      def initialize(logger)
        @logger = logger
      end

      def info(progname = nil, &)
        logger.info(progname, &)
      end

      def start_processing(_event)
        info { 'Started POST /rails/action_mailbox/ses/inbound_emails' }
      end

      prepend Toybaco::InboundEmail::SesIngressLogSubscriber
    end.new(logger)

    described_class.store_ses_route_token(fixture_source)
    event = Struct.new(:payload).new(
      {
        controller: 'ses/inbound_emails',
        action: 'create',
        path: '/ses/inbound_emails',
        params: {},
        headers: {}
      }
    )
    subscriber.start_processing(event)

    expect(messages.any? { |text| text.include?('Started POST') }).to be(true)
    expect(messages.any? { |text| filter_pattern_line?(text) }).to be(true)
  ensure
    described_class.clear_ses_route_token
  end

  it 'Lograge process_action の同じ logger に route-log を出す' do
    messages = []
    logger = instance_double(Logger)
    allow(logger).to receive(:info) do |msg = nil, &block|
      messages << (block ? block.call : msg).to_s
    end

    subscriber = Class.new do
      attr_reader :logger

      def initialize(logger)
        @logger = logger
      end

      def process_action(_event)
        logger.info('{"method":"POST","status":204}')
      end

      prepend Toybaco::InboundEmail::SesIngressLogrageSubscriber
    end.new(logger)

    described_class.store_ses_route_token(fixture_source)
    event = Struct.new(:payload).new(
      {
        controller: 'action_mailbox/ingresses/ses/inbound_emails',
        action: 'create',
        status: 204,
        path: '/rails/action_mailbox/ses/inbound_emails',
        params: {},
        headers: {}
      }
    )
    subscriber.process_action(event)

    expect(messages.any? { |text| text.include?('"status":204') }).to be(true)
    expect(messages.any? { |text| filter_pattern_line?(text) }).to be(true)
  ensure
    described_class.clear_ses_route_token
  end

  it '起動バナーは toybaco-inbound-hooks-loaded の一意部分を1行出す' do
    described_class.instance_variable_set(:@inbound_hooks_loaded_banner_emitted, false)
    expect { described_class.emit_inbound_hooks_loaded_banner! }.to output(
      a_string_including('toybaco-inbound-hooks-loaded=e148640e9ee1')
    ).to_stdout
  end

  it 'LogSubscriber process_action の Completed 204 と同じ info に route-log を出す' do
    messages = []
    logger = instance_double(Logger)
    allow(logger).to receive(:info) do |msg = nil, &block|
      messages << (block ? block.call : msg).to_s
    end

    subscriber = Class.new do
      attr_reader :logger

      def initialize(logger)
        @logger = logger
      end

      def info(progname = nil, &)
        logger.info(progname, &)
      end

      def process_action(event)
        info { "Completed #{event.payload[:status]} No Content" }
      end

      prepend Toybaco::InboundEmail::SesIngressLogSubscriber
    end.new(logger)

    described_class.store_ses_route_token(fixture_source)
    event = Struct.new(:payload).new(
      {
        controller: 'ActionMailbox::Ingresses::Ses::InboundEmailsController',
        action: 'create',
        status: 204,
        path: '/rails/action_mailbox/ses/inbound_emails',
        params: {},
        headers: {}
      }
    )
    subscriber.process_action(event)

    expect(messages.any? { |text| text.include?('Completed 204') }).to be(true)
    expect(messages.any? { |text| filter_pattern_line?(text) }).to be(true)
    expect(messages.any? { |text| text.include?('toybaco-fixture-') }).to be(true)
  ensure
    described_class.clear_ses_route_token
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

  # stdout の行も LogScrub(CASA 6.5.1)に通す。logger は元の STDOUT を持つので、ここで捕まえるのは $stdout.puts の行だけ。
  def stdout_of
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  it 'Message-ID がアドレスの形でも stdout の route-log はアドレスを伏せ、行頭・marker・mailbox・Conversation を残す' do
    described_class.clear_ses_route_token
    source = fixture_source.sub('<rewritten@unknown.host>', '<route.customer+tag@mail.example.com>')

    output = stdout_of { described_class.log_ses_create_route(source: source) }

    expect(output).to eq(
      "toybaco-route-log toybaco-fixture-#{token} mailbox=SupportMailbox Conversation=no message_id=<[FILTERED_EMAIL]>\n"
    )
    expect(output).not_to match(Toybaco::Security::LogScrub::EMAIL)
    expect(output).not_to include('route.customer')
  ensure
    described_class.clear_ses_route_token
  end

  it 'fixture の Message-ID でも stdout の行が受信の E2E の route と created の式に一致する' do
    described_class.clear_ses_route_token
    source = fixture_source.sub('<rewritten@unknown.host>', "<toybaco-fixture-#{token}@inbox.staging.toybaco.jp>")
    # .github/workflows/staging-inbound-email-fixture.yml の evaluate_fixture_evidence の --arg route / created と同じ形。
    route = /(^|[[:space:]])toybaco-route-log toybaco-fixture-#{token}([[:space:]]|$)/
    created = /(^|[[:space:]])toybaco-route-log toybaco-fixture-#{token} mailbox=SupportMailbox Conversation=yes([[:space:]]|$)/

    routed = stdout_of { described_class.log_ses_create_route(source: source) }
    created_line = described_class.log_mailbox_route(Mail.new(source), mailbox: 'SupportMailbox', conversation: true, raw: source)
    created_output = stdout_of { described_class.emit_cloudwatch_line(created_line) }

    expect(routed.lines.grep(route)).not_to be_empty
    expect(created_output.lines.grep(created)).not_to be_empty
    expect(routed + created_output).to include('message_id=<[FILTERED_EMAIL]>')
    expect(routed + created_output).not_to match(Toybaco::Security::LogScrub::EMAIL)
  ensure
    described_class.clear_ses_route_token
  end

  it '経路の不一致の行も stdout では LogScrub を通し、controller 名の部分は変えない' do
    expected = "expected=#{described_class::INGRESS_CONTROLLER}"
    prefix = "toybaco-ses-route-mismatch #{expected}"

    masked = stdout_of { described_class.emit_ses_route_mismatch("#{expected} owner=ops.mismatch@mail.example.com") }
    plain = stdout_of { described_class.emit_ses_route_mismatch("#{expected} actual=action_mailbox/ingresses/ses/inbound_emails") }

    expect(masked).to start_with("#{prefix} ")
    expect(masked).to include(Toybaco::Security::LogScrub::FILTERED_EMAIL)
    expect(masked).not_to match(Toybaco::Security::LogScrub::EMAIL)
    expect(masked).not_to include('ops.mismatch')
    expect(plain).to eq("#{prefix} actual=action_mailbox/ingresses/ses/inbound_emails\n")
  end
end
