# frozen_string_literal: true

require 'json'
require 'stringio'
require 'minitest/autorun'

unless String.method_defined?(:exclude?)
  class String
    def exclude?(other)
      index(other).nil?
    end
  end
end
require_relative '../overlay/app/lib/toybaco/inbound_email'
require_relative '../scripts/toybaco-inbound-email-sns-fixture'

class ToybacoInboundEmailTest < Minitest::Test
  FakeResolver = Struct.new(:hosts) do
    def records(_domain)
      hosts
    end
  end

  def env(overrides = {})
    {
      'MAILER_INBOUND_EMAIL_DOMAIN' => 'inbox.toybaco.jp',
      'RAILS_INBOUND_EMAIL_SERVICE' => 'ses',
      'ACTION_MAILBOX_SES_SNS_TOPIC' => 'arn:aws:sns:ap-northeast-1:951034765053:toybaco-inbound-email',
      'TOYBACO_INBOUND_EMAIL_MX' => Toybaco::InboundEmail::TOKYO_MX,
      'TOYBACO_INBOUND_EMAIL_REGION' => Toybaco::InboundEmail::TOKYO_REGION
    }.merge(overrides)
  end

  def ready_resolver
    FakeResolver.new([Toybaco::InboundEmail::TOKYO_MX])
  end

  def test_ready_when_tokyo_ses_inbound_and_mx_match
    status = Toybaco::InboundEmail.readiness(env, resolver: ready_resolver)

    assert(status[:ready])
    assert_empty(status[:reasons])
  end

  def test_mailbox_address_is_deterministic_per_account
    assert_equal 'shop-6@inbox.toybaco.jp', Toybaco::InboundEmail.mailbox_address(6, env)
    assert_equal(
      'shop-6@inbox.staging.toybaco.jp',
      Toybaco::InboundEmail.mailbox_address(6, env('MAILER_INBOUND_EMAIL_DOMAIN' => 'inbox.staging.toybaco.jp'))
    )
  end

  def test_missing_domain_fails_closed
    status = Toybaco::InboundEmail.readiness(env('MAILER_INBOUND_EMAIL_DOMAIN' => ''), resolver: ready_resolver)

    refute(status[:ready])
    assert_includes(status[:reasons].join, '受信ドメインが未設定')
  end

  def test_foreign_domain_fails_closed
    status = Toybaco::InboundEmail.readiness(
      env('MAILER_INBOUND_EMAIL_DOMAIN' => 'mail.example.com'),
      resolver: ready_resolver
    )

    refute(status[:ready])
    assert_includes(status[:reasons].join, '許可された inbox サブドメイン')
  end

  def test_imap_or_blank_ingress_fails_closed
    %w[relay imap mailgun].each do |service|
      status = Toybaco::InboundEmail.readiness(
        env('RAILS_INBOUND_EMAIL_SERVICE' => service),
        resolver: ready_resolver
      )
      refute(status[:ready], service)
      assert_includes(status[:reasons].join, 'ses ではありません', service)
    end
  end

  def test_non_tokyo_sns_topic_fails_closed
    status = Toybaco::InboundEmail.readiness(
      env('ACTION_MAILBOX_SES_SNS_TOPIC' => 'arn:aws:sns:us-east-1:951034765053:toybaco-inbound-email'),
      resolver: ready_resolver
    )

    refute(status[:ready])
    assert_includes(status[:reasons].join, '東京リージョン')
  end

  def test_wrong_mx_or_missing_mx_fails_closed
    missing = Toybaco::InboundEmail.readiness(env, resolver: FakeResolver.new([]))
    other = Toybaco::InboundEmail.readiness(
      env,
      resolver: FakeResolver.new(['inbound-smtp.us-east-1.amazonaws.com'])
    )

    refute(missing[:ready])
    refute(other[:ready])
    assert_includes(missing[:reasons].join, 'MX')
    assert_includes(other[:reasons].join, 'MX')
  end

  def test_provision_does_not_create_inbox_when_not_ready
    account = StubAccount.new(id: 6)
    created = false

    error = assert_raises(Toybaco::InboundEmail::NotReady) do
      Toybaco::InboundEmail.provision!(
        account,
        environment: env('MAILER_INBOUND_EMAIL_DOMAIN' => ''),
        resolver: ready_resolver,
        factory: lambda { |*_args|
          created = true
          {}
        }
      )
    end

    refute(created)
    assert_equal 'blocked', account.internal_attributes.dig('toybaco_inbound_email', 'status')
    assert_match(/受信ドメイン/, error.message)
  end

  def test_provision_creates_ready_mailbox_when_mx_is_live
    account = StubAccount.new(id: 6)
    seen = nil

    result = Toybaco::InboundEmail.provision!(
      account,
      environment: env,
      resolver: ready_resolver,
      factory: lambda { |target, address|
        seen = [target.id, address]
        { channel: :channel, inbox: :inbox, created: true }
      }
    )

    assert_equal [6, 'shop-6@inbox.toybaco.jp'], seen
    assert_equal 'shop-6@inbox.toybaco.jp', result[:address]
    assert_equal 'ready', account.internal_attributes.dig('toybaco_inbound_email', 'status')
    assert_equal 'メール', account.internal_attributes.dig('toybaco_inbound_email', 'inbox_name')
  end

  def test_ingest_new_mail_to_channel_email_or_forward_address
    mailboxes = [
      { email: 'shop-6@inbox.toybaco.jp', forward_to_email: 'aabbcc@inbox.toybaco.jp', account_id: 6 }
    ]
    notification = {
      'notificationType' => 'Received',
      'mail' => { 'destination' => ['Shop-6@inbox.toybaco.jp'] }
    }

    routed = Toybaco::InboundEmail.route(notification, mailboxes: mailboxes)
    assert_equal :new_conversation, routed[:action]
    assert_equal 'shop-6@inbox.toybaco.jp', routed[:address]
    assert_equal 6, routed[:mailbox][:account_id]

    forwarded = Toybaco::InboundEmail.route(
      { 'to' => ['aabbcc@inbox.toybaco.jp'] },
      mailboxes: mailboxes
    )
    assert_equal :new_conversation, forwarded[:action]
    assert_equal 'aabbcc@inbox.toybaco.jp', forwarded[:address]
  end

  def test_ingest_reply_plus_uuid_continues_conversation
    routed = Toybaco::InboundEmail.route(
      { 'mail' => { 'destination' => ['reply+6bdc3f4d-0bec-4515-a284-5d916fdde489@inbox.toybaco.jp'] } },
      mailboxes: [{ email: 'shop-6@inbox.toybaco.jp' }]
    )

    assert_equal :reply, routed[:action]
    assert_equal '6bdc3f4d-0bec-4515-a284-5d916fdde489', routed[:conversation_uuid]
  end

  def test_unknown_destination_is_rejected_not_dropped
    error = assert_raises(Toybaco::InboundEmail::Rejected) do
      Toybaco::InboundEmail.route(
        { 'mail' => { 'destination' => ['unknown@inbox.toybaco.jp'] } },
        mailboxes: [{ email: 'shop-6@inbox.toybaco.jp' }]
      )
    end
    assert_match(/一致する宛先/, error.message)
  end

  def test_malformed_or_empty_destination_is_rejected
    error = assert_raises(Toybaco::InboundEmail::Rejected) do
      Toybaco::InboundEmail.route({ 'mail' => { 'destination' => [] } }, mailboxes: [])
    end
    assert_match(/宛先がありません/, error.message)
  end

  def test_sns_unwrap_accepts_notification_and_confirmation_without_url
    wrapped = Toybaco::InboundEmail.unwrap_sns(
      {
        'Type' => 'Notification',
        'Message' => JSON.generate('mail' => { 'destination' => ['shop-6@inbox.toybaco.jp'] })
      }
    )
    assert_equal :received, wrapped[:kind]
    assert_equal ['shop-6@inbox.toybaco.jp'], wrapped[:notification].dig('mail', 'destination')

    confirm = Toybaco::InboundEmail.unwrap_sns('Type' => 'SubscriptionConfirmation')
    assert_equal :subscription_confirmation, confirm[:kind]
    refute(confirm.key?(:subscribe_url))
  end

  def test_unknown_sns_type_is_rejected
    assert_raises(Toybaco::InboundEmail::Rejected) do
      Toybaco::InboundEmail.unwrap_sns('Type' => 'UnsubscribeConfirmation')
    end
  end

  def test_ingress_enabled_when_tokyo_ses_env_is_set
    assert(Toybaco::InboundEmail.ingress_enabled?(env))
    assert(
      Toybaco::InboundEmail.ingress_enabled?(
        env('MAILER_INBOUND_EMAIL_DOMAIN' => 'inbox.staging.toybaco.jp')
      )
    )
  end

  def test_ingress_enabled_does_not_require_live_mx
    assert(Toybaco::InboundEmail.ingress_enabled?(env))
    refute(Toybaco::InboundEmail.ready?(env, resolver: FakeResolver.new([])))
  end

  def test_ingress_disabled_without_ses_env
    refute(Toybaco::InboundEmail.ingress_enabled?(env('RAILS_INBOUND_EMAIL_SERVICE' => '')))
    refute(Toybaco::InboundEmail.ingress_enabled?(env('RAILS_INBOUND_EMAIL_SERVICE' => 'relay')))
    refute(Toybaco::InboundEmail.ingress_enabled?(env('MAILER_INBOUND_EMAIL_DOMAIN' => '')))
    refute(Toybaco::InboundEmail.ingress_enabled?(env('ACTION_MAILBOX_SES_SNS_TOPIC' => '')))
    refute(
      Toybaco::InboundEmail.ingress_enabled?(
        env('ACTION_MAILBOX_SES_SNS_TOPIC' => 'arn:aws:sns:us-east-1:951034765053:toybaco-inbound-email')
      )
    )
  end

  def test_overlay_initializer_draws_ses_ingress_only_when_enabled
    initializer_path = File.expand_path(
      '../overlay/app/config/initializers/toybaco_inbound_email.rb',
      __dir__
    )
    skip 'Chatwoot overlay initializer はこの品質スナップショットに含まれない' unless
      File.file?(initializer_path)

    initializer = File.read(initializer_path)

    assert_includes initializer, 'register_ses_ingress_route_block!'
    assert_includes initializer, 'SesInboundRouteMiddleware'
    assert_includes initializer, 'warn_unless_ses_route_is_ours!'
    assert_includes initializer, 'install_action_mailbox_hooks!'
    assert_includes initializer, 'install_ses_ingress_reload_hooks!'
    assert_includes initializer, 'warn_unless_ses_controller_loaded!'
    assert_includes initializer, 'ensure_ses_ingress_route!'
    assert_includes initializer, 'emit_inbound_hooks_loaded_banner!'
    assert_includes initializer, 'toybaco-inbound-hooks-loaded'
    assert_includes initializer, 'after_initialize'
    assert_includes initializer, 'mount Engine =>'
    assert_includes initializer, 'unshift'
    refute_includes initializer, 'insert_before 0'
    refute_includes initializer, 'Rails.application.routes.append'
    refute_includes initializer, 'module: Toybaco::InboundEmail::INGRESS_MODULE'
    refute_match(/SubscribeURL|SubscriptionConfirmation/, initializer)

    mount = File.read(File.expand_path('../overlay/app/lib/toybaco/inbound_email/ses_route_mount.rb', __dir__))
    assert_includes mount, 'routes.prepend'
    assert_includes mount, 'ingress_enabled?'
    assert_includes mount, 'ensure_ses_ingress_route!'
    assert_includes mount, 'reload_routes!'
    assert_includes mount, 'INGRESS_PATH'
    assert_includes mount, 'INGRESS_TO'
    assert_includes mount, 'INGRESS_AS'
    assert_includes mount, 'INGRESS_GET_TO'
    assert_includes mount, 'INGRESS_GET_AS'
    assert_includes mount, 'post '
    assert_includes mount, 'get '
    assert_includes mount, 'toybaco-ses-route-mismatch'
    assert_includes mount, 'recognize_path'

    controller_path = File.expand_path(
      '../overlay/app/app/controllers/toybaco/inbound_email_ingress_controller.rb',
      __dir__
    )
    skip 'Chatwoot overlay controller はこの品質スナップショットに含まれない' unless
      File.file?(controller_path)

    controller = File.read(controller_path)
    assert_includes controller, 'def method_not_allowed'
    assert_includes controller, 'head :method_not_allowed'
    refute_match(/SubscribeURL|SubscriptionConfirmation/, controller)
  end

  def test_ingress_route_constants_match_action_mailbox_ses
    assert_equal '/rails/action_mailbox/ses/inbound_emails', Toybaco::InboundEmail::INGRESS_PATH
    assert_equal '/rails/action_mailbox', Toybaco::InboundEmail::INGRESS_SCOPE
    assert_equal 'action_mailbox/ingresses', Toybaco::InboundEmail::INGRESS_MODULE
    assert_equal '/ses/inbound_emails', Toybaco::InboundEmail::INGRESS_ROUTE_PATH
    assert_equal 'toybaco/ses_inbound_emails#create', Toybaco::InboundEmail::INGRESS_TO
    assert_equal 'toybaco/ses_inbound_emails', Toybaco::InboundEmail::INGRESS_CONTROLLER
    assert_equal 'ActionMailbox::Ingresses::Ses::InboundEmailsController',
                 Toybaco::InboundEmail::INGRESS_SES_CONTROLLER
    assert_equal 'toybaco-ses-route-mismatch', Toybaco::InboundEmail::ROUTE_MISMATCH_PREFIX
    assert_equal :toybaco_rails_ses_inbound_emails, Toybaco::InboundEmail::INGRESS_AS
    assert_equal 'toybaco/inbound_email_ingress#method_not_allowed', Toybaco::InboundEmail::INGRESS_GET_TO
    assert_equal :toybaco_rails_ses_inbound_emails_get, Toybaco::InboundEmail::INGRESS_GET_AS
    assert_equal(
      Toybaco::InboundEmail::INGRESS_PATH,
      "#{Toybaco::InboundEmail::INGRESS_SCOPE}#{Toybaco::InboundEmail::INGRESS_ROUTE_PATH}"
    )
    assert_equal [400, 401, 403, 405, 415, 422], Toybaco::InboundEmail::ALLOWED_INGRESS_STATUSES
    refute_includes Toybaco::InboundEmail::ALLOWED_INGRESS_STATUSES, 404
  end

  def test_sns_fixture_is_notification_equivalent_and_routes_to_staging_shop
    built = Toybaco::InboundEmail::SnsFixture.build(account_id: 6, token: 'cafef00d')
    payload = built.fetch(:payload)

    assert_equal 'Notification', payload.fetch('Type')
    assert_equal Toybaco::InboundEmail::SnsFixture::STAGING_TOPIC_ARN, payload.fetch('TopicArn')
    refute_includes JSON.generate(payload), Toybaco::InboundEmail::SnsFixture::PRODUCTION_ACCOUNT_ID
    refute_match(/SubscribeURL|sns\.ap-northeast-1\.amazonaws\.com/, JSON.generate(payload))

    unwrapped = Toybaco::InboundEmail.unwrap_sns(payload)
    assert_equal :received, unwrapped[:kind]
    assert_equal 'Received', unwrapped[:notification].fetch('notificationType')
    assert_equal 'SNS', unwrapped[:notification].dig('receipt', 'action', 'type')
    assert_includes unwrapped[:notification].fetch('content'), 'shop-6@inbox.staging.toybaco.jp'

    routed = Toybaco::InboundEmail.route(
      unwrapped.fetch(:notification),
      mailboxes: [{ email: 'shop-6@inbox.staging.toybaco.jp', account_id: 6 }]
    )
    assert_equal :new_conversation, routed[:action]
    assert_equal 'shop-6@inbox.staging.toybaco.jp', routed[:address]
    assert_equal 'cafef00d', built.fetch(:token)

    source = Toybaco::InboundEmail::SnsFixture.action_mailbox_source(payload)
    assert_match(/\AX-Original-To: shop-6@inbox\.staging\.toybaco\.jp\r\n/, source)
    assert_includes source, "Delivered-To: shop-6@inbox.staging.toybaco.jp"
    assert_includes source, "To: shop-6@inbox.staging.toybaco.jp"
    assert_includes source, '<toybaco-fixture-cafef00d@inbox.staging.toybaco.jp>'
    assert_includes source, 'X-Toybaco-Fixture: toybaco-fixture-cafef00d'
    refute_includes source, Toybaco::InboundEmail::SnsFixture::PRODUCTION_ACCOUNT_ID
  end

  def test_sns_fixture_action_mailbox_source_rejects_s3_action
    built = Toybaco::InboundEmail::SnsFixture.build(account_id: 6, token: 'cafef00d')
    payload = built.fetch(:payload)
    ses = JSON.parse(payload.fetch('Message'))
    ses['receipt']['action'] = {
      'type' => 'S3',
      'bucketName' => 'toybaco-staging-inbound-email',
      'objectKey' => 'inbound/secret'
    }
    payload['Message'] = JSON.generate(ses)

    error = assert_raises(Toybaco::InboundEmail::Rejected) do
      Toybaco::InboundEmail::SnsFixture.action_mailbox_source(payload)
    end
    assert_match(/S3/, error.message)
  end

  def test_sns_fixture_rejects_production_topic_and_unknown_destination
    error = assert_raises(Toybaco::InboundEmail::Rejected) do
      Toybaco::InboundEmail::SnsFixture.build(
        topic_arn: 'arn:aws:sns:ap-northeast-1:951034765053:toybaco-inbound-email'
      )
    end
    assert_match(/staging inbound/, error.message)

    built = Toybaco::InboundEmail::SnsFixture.build(account_id: 0, token: 'deadbeef')
    assert_raises(Toybaco::InboundEmail::Rejected) do
      Toybaco::InboundEmail.route(
        Toybaco::InboundEmail.unwrap_sns(built.fetch(:payload)).fetch(:notification),
        mailboxes: [{ email: 'shop-6@inbox.staging.toybaco.jp' }]
      )
    end
  end

  def test_sns_fixture_cli_writes_json_without_printing_body
    built = Toybaco::InboundEmail::SnsFixture.build(account_id: 1, token: '01234567')
    payload = built.fetch(:payload)
    receipt = "token=#{built.fetch(:token)}\naccount=staging\nkind=Notification\n"

    assert_equal '01234567', built.fetch(:token)
    assert_equal 'Notification', payload.fetch('Type')
    assert_equal 'Received', built.fetch(:ses).fetch('notificationType')
    assert_equal(
      ['shop-1@inbox.staging.toybaco.jp'],
      Toybaco::InboundEmail::SnsFixture.destinations_of(payload)
    )
    refute_includes receipt, 'fixture-sender'
    refute_includes receipt, 'shop-1@'
    refute_includes receipt, payload.fetch('Message')
  end

  def test_topic_policy_verdict_allows_only_staging_deploy_plus_ses
    allow = {
      'Version' => '2012-10-17',
      'Statement' => [
        {
          'Sid' => 'AllowSESPublishTokyo',
          'Effect' => 'Allow',
          'Principal' => { 'Service' => 'ses.amazonaws.com' },
          'Action' => 'sns:Publish'
        },
        {
          'Sid' => 'AllowStagingGithubDeployPublish',
          'Effect' => 'Allow',
          'Principal' => { 'AWS' => Toybaco::InboundEmail::SnsFixture::STAGING_DEPLOY_ROLE_ARN },
          'Action' => 'sns:Publish'
        }
      ]
    }

    assert_equal(
      Toybaco::InboundEmail::SnsFixture::POLICY_ALLOW_STAGING_DEPLOY,
      Toybaco::InboundEmail::SnsFixture.topic_policy_verdict(JSON.generate(allow))
    )
    assert_equal(
      Toybaco::InboundEmail::SnsFixture::POLICY_ALLOW_STAGING_DEPLOY,
      Toybaco::InboundEmail::SnsFixture.topic_policy_verdict('Attributes' => { 'Policy' => JSON.generate(allow) })
    )
  end

  def test_topic_policy_verdict_fails_closed_on_ses_only_or_unsafe
    ses_only = {
      'Version' => '2012-10-17',
      'Statement' => [{
        'Effect' => 'Allow',
        'Principal' => { 'Service' => 'ses.amazonaws.com' },
        'Action' => 'sns:Publish'
      }]
    }
    assert_equal(
      Toybaco::InboundEmail::SnsFixture::POLICY_DENIES_STAGING_DEPLOY,
      Toybaco::InboundEmail::SnsFixture.topic_policy_verdict(ses_only)
    )

    wildcard = {
      'Statement' => [{
        'Effect' => 'Allow',
        'Principal' => '*',
        'Action' => 'sns:Publish'
      }]
    }
    assert_equal(
      Toybaco::InboundEmail::SnsFixture::POLICY_WILDCARD_PUBLISH,
      Toybaco::InboundEmail::SnsFixture.topic_policy_verdict(wildcard)
    )

    production = {
      'Statement' => [{
        'Effect' => 'Allow',
        'Principal' => { 'AWS' => 'arn:aws:iam::951034765053:role/toybaco-github-deploy-staging' },
        'Action' => 'sns:Publish'
      }]
    }
    assert_equal(
      Toybaco::InboundEmail::SnsFixture::POLICY_UNSAFE_PRODUCTION,
      Toybaco::InboundEmail::SnsFixture.topic_policy_verdict(production)
    )

    missing_ses = {
      'Statement' => [{
        'Effect' => 'Allow',
        'Principal' => { 'AWS' => Toybaco::InboundEmail::SnsFixture::STAGING_DEPLOY_ROLE_ARN },
        'Action' => 'sns:Publish'
      }]
    }
    assert_equal(
      Toybaco::InboundEmail::SnsFixture::POLICY_MISSING_SES,
      Toybaco::InboundEmail::SnsFixture.topic_policy_verdict(missing_ses)
    )

    assert_equal(
      Toybaco::InboundEmail::SnsFixture::POLICY_INVALID,
      Toybaco::InboundEmail::SnsFixture.topic_policy_verdict('not-json')
    )
  end

  def test_action_mailbox_routes_x_original_to_and_delivered_to_to_support
    mail = {
      to: nil,
      cc: nil,
      'X-Original-To' => 'shop-1@inbox.staging.toybaco.jp',
      'Delivered-To' => 'shop-1@inbox.staging.toybaco.jp'
    }

    assert(Toybaco::InboundEmail.valid_mailbox_recipients?(mail))
    assert_equal(
      :support,
      Toybaco::InboundEmail.mailbox_route(mail, channel_found: true)
    )
    assert_equal(
      :default,
      Toybaco::InboundEmail.mailbox_route(mail, channel_found: false)
    )
    assert_includes(
      Toybaco::InboundEmail.mailbox_recipients(mail),
      'shop-1@inbox.staging.toybaco.jp'
    )
  end

  def test_action_mailbox_string_to_still_uses_envelope_headers
    mail = {
      to: "X-Original-To: shop-1@inbox.staging.toybaco.jp\r",
      'X-Original-To' => "shop-1@inbox.staging.toybaco.jp\r",
      'Delivered-To' => '<shop-1@inbox.staging.toybaco.jp>'
    }

    assert(Toybaco::InboundEmail.valid_mailbox_recipients?(mail))
    assert_equal(
      :support,
      Toybaco::InboundEmail.mailbox_route(mail, channel_found: true)
    )
    assert_equal(
      ['shop-1@inbox.staging.toybaco.jp'],
      Toybaco::InboundEmail.mailbox_recipients(mail)
    )
  end

  def test_action_mailbox_empty_recipients_still_default
    mail = { to: nil, cc: nil }

    refute(Toybaco::InboundEmail.valid_mailbox_recipients?(mail))
    assert_equal(:default, Toybaco::InboundEmail.mailbox_route(mail, channel_found: true))
  end

  def test_action_mailbox_reply_plus_uuid_stays_on_reply_mailbox
    mail = { to: ['reply+6bdc3f4d-0bec-4515-a284-5d916fdde489@inbox.staging.toybaco.jp'] }

    assert_equal(:reply, Toybaco::InboundEmail.mailbox_route(mail, channel_found: true))
  end

  def test_mailbox_route_log_includes_support_mailbox_and_message_id
    log = Toybaco::InboundEmail.mailbox_route_log(
      mailbox: 'SupportMailbox',
      message_id: '<toybaco-fixture-cafef00d@inbox.staging.toybaco.jp>',
      conversation: true
    )

    assert_includes log, 'SupportMailbox'
    assert_includes log, 'Conversation=yes'
    assert_includes log, 'toybaco-fixture-cafef00d'
    refute_match(/conversation_id=\d+/, log)
    refute_includes log, 'fixture-sender'
  end

  def test_mailbox_route_log_keeps_fixture_token_when_message_id_rewritten
    log = Toybaco::InboundEmail.mailbox_route_log(
      mailbox: 'SupportMailbox',
      message_id: '<rewritten@unknown.host>',
      conversation: false,
      raw: "Message-ID: <toybaco-fixture-cafef00d@inbox.staging.toybaco.jp>\r\n\r\nfixture"
    )

    assert_includes log, 'SupportMailbox'
    assert_includes log, 'Conversation=no'
    assert_includes log, 'toybaco-fixture-cafef00d'
    refute_includes log, 'fixture-sender'
    refute_includes log, "\nfixture"
    refute_match(/conversation_id=\d+/, log)
  end

  def test_ingress_mailbox_route_log_joins_token_mailbox_and_conversation
    source = [
      'From: Fixture Sender <fixture-sender@example.invalid>',
      'To: shop-1@inbox.staging.toybaco.jp',
      'Delivered-To: shop-1@inbox.staging.toybaco.jp',
      'X-Original-To: shop-1@inbox.staging.toybaco.jp',
      'Subject: toybaco inbound fixture',
      'Message-ID: <rewritten@unknown.host>',
      'X-Toybaco-Fixture: toybaco-fixture-cafef00d',
      '',
      'fixture'
    ].join("\r\n")

    log = nil
    out = capture_io { log = Toybaco::InboundEmail.log_ingress_mailbox_route(source, channel_found: true) }.first

    assert_same_line_route_contract(log, token: 'cafef00d')
    assert_includes out, "toybaco-fixture-cafef00d"
    assert_includes out, 'mailbox=SupportMailbox'
    assert_match(/Conversation=(yes|no)/, out)
  end

  def test_ses_create_route_log_matches_filter_pattern_on_same_line
    source = [
      'From: Fixture Sender <fixture-sender@example.invalid>',
      'To: shop-1@inbox.staging.toybaco.jp',
      'Delivered-To: shop-1@inbox.staging.toybaco.jp',
      'X-Original-To: shop-1@inbox.staging.toybaco.jp',
      'Subject: toybaco inbound fixture',
      'Message-ID: <rewritten@unknown.host>',
      'X-Toybaco-Fixture: toybaco-fixture-cafef00d',
      '',
      'fixture'
    ].join("\r\n")

    log = nil
    out = capture_io { log = Toybaco::InboundEmail.log_ses_create_route(source: source) }.first

    assert_same_line_route_contract(log, token: 'cafef00d')
    assert_includes out, "toybaco-fixture-cafef00d"
    assert_includes out, 'mailbox=SupportMailbox'
    assert_match(/Conversation=(yes|no)/, out)
    refute_includes out.split("\n").find { |line| line.include?('mailbox=SupportMailbox') }.to_s, 'fixture-sender'
  end

  def test_ses_ingress_route_targets_overlay_subclass_of_gem_controller
    controller_path = File.expand_path(
      '../overlay/app/app/controllers/toybaco/ses_inbound_emails_controller.rb',
      __dir__
    )
    manifest_path = File.expand_path('../tests/chatwoot-overlay-manifest.tsv', __dir__)
    skip 'SES overlay controller はこの品質スナップショットに含まれない' unless
      File.file?(controller_path) && File.file?(manifest_path)

    source = File.read(controller_path)
    manifest = File.read(manifest_path)
    initializer = File.read(
      File.expand_path('../overlay/app/config/initializers/toybaco_inbound_email.rb', __dir__)
    )

    assert_includes source, 'class Toybaco::SesInboundEmailsController < ActionMailbox::Ingresses::Ses::InboundEmailsController'
    assert_includes source, Toybaco::InboundEmail::INGRESS_SES_CONTROLLER
    assert_includes source, 'def create'
    assert_includes source, 'ensure'
    assert_includes source, 'log_ses_create_route'
    assert_includes source, 'load_ses_ingress_controller!'
    assert_includes source, 'response&.status == 204'
    mount = File.read(File.expand_path('../overlay/app/lib/toybaco/inbound_email/ses_route_mount.rb', __dir__))
    assert_includes mount, 'to: INGRESS_TO'
    assert_includes mount, 'post INGRESS_PATH'
    assert_includes mount, 'routes.prepend'
    assert_includes initializer, 'register_ses_ingress_route_block!'
    assert_includes initializer, 'SesInboundRouteMiddleware'
    assert_includes initializer, 'install_ses_ingress_reload_hooks!'
    assert_includes manifest, "\toverlay/app/app/controllers/toybaco/ses_inbound_emails_controller.rb"
    assert_includes manifest, "\toverlay/app/lib/toybaco/inbound_email/ses_route_mount.rb"
    assert_includes manifest, "\toverlay/app/lib/toybaco/inbound_email/ses_inbound_route_middleware.rb"
    assert_includes manifest, "\toverlay/app/lib/toybaco/inbound_email/ses_ingress_reload_helpers.rb"
    assert_includes manifest, "\toverlay/app/lib/toybaco/inbound_email/ses_ingress_log_subscriber.rb"
    assert_includes manifest, "\toverlay/app/lib/toybaco/inbound_email/ses_ingress_process_action.rb"
    assert_includes manifest, "\toverlay/app/lib/toybaco/inbound_email/ses_ingress_lograge.rb"
    assert_includes manifest, "\toverlay/app/lib/toybaco/inbound_email/ses_ingress_boot.rb"
    assert_includes manifest, "\toverlay/app/lib/toybaco/inbound_email/ses_ingress_route_emit.rb"
    assert_includes manifest, "\toverlay/app/lib/toybaco/inbound_email/ses_ingress_reload_hook.rb"
    refute_match(/SubscribeURL|conversation_id=\d+/, source)
  end

  def test_ses_ingress_live_routes_recognize_overlay_subclass
    overlay = Class.new do
      def recognize_path(_path, *)
        { controller: 'toybaco/ses_inbound_emails', action: 'create' }
      end
    end.new
    gem_controller = Class.new do
      def recognize_path(_path, *)
        { controller: 'action_mailbox/ingresses/ses/inbound_emails', action: 'create' }
      end
    end.new

    assert_equal 'toybaco/ses_inbound_emails', Toybaco::InboundEmail.recognized_ses_controller(overlay)
    assert Toybaco::InboundEmail.ses_ingress_mounted_on_overlay?(overlay)
    assert_equal 'action_mailbox/ingresses/ses/inbound_emails',
                 Toybaco::InboundEmail.recognized_ses_controller(gem_controller)
    refute Toybaco::InboundEmail.ses_ingress_mounted_on_overlay?(gem_controller)
  end

  def test_ses_route_mismatch_boot_check_emits_error
    routes = Class.new do
      def recognize_path(_path, *)
        { controller: 'action_mailbox/ingresses/ses/inbound_emails', action: 'create' }
      end
    end.new

    stdout, = capture_io do
      @mismatch = Toybaco::InboundEmail.warn_unless_ses_route_is_ours!(routes)
    end
    combined = [@mismatch, stdout].join

    assert_includes combined, 'toybaco-ses-route-mismatch'
    assert_includes combined, 'toybaco/ses_inbound_emails'
    assert_includes combined, 'action_mailbox/ingresses/ses/inbound_emails'
    refute_match(/SubscribeURL|conversation_id=\d+/, combined)
  end

  def test_ses_ingress_reload_hook_resolves_controller_names_without_name_error
    names = Toybaco::InboundEmail::SesIngressReloadHook::SES_INGRESS_CONTROLLER_NAMES
    resolved = Toybaco::InboundEmail.zeitwerk_ses_class_names

    assert_includes names, Toybaco::InboundEmail::INGRESS_SES_CONTROLLER
    assert_includes resolved, Toybaco::InboundEmail::INGRESS_SES_CONTROLLER
    assert_includes resolved, 'ActionMailbox::RoutingJob'
    assert_includes resolved, 'ActionMailbox::InboundEmail'
    refute_includes names, nil
    loader = Object.new
    seen = []
    loader.define_singleton_method(:on_load) { |name, *_args, &_| seen << name }
    rails = Module.new do
      define_singleton_method(:autoloaders) { [loader] }
    end
    hide = Object.const_defined?(:Rails)
    previous = Object.const_get(:Rails) if hide
    Object.send(:remove_const, :Rails) if hide
    Object.const_set(:Rails, rails)
    begin
      Toybaco::InboundEmail.install_ses_ingress_reload_hooks!
    ensure
      Object.send(:remove_const, :Rails)
      Object.const_set(:Rails, previous) if hide
    end

    assert_includes seen, Toybaco::InboundEmail::INGRESS_SES_CONTROLLER
    assert_includes seen, 'ActionMailbox::RoutingJob'
  end

  def test_log_subscriber_process_action_emits_route_log_on_ses_create_204
    source = shop1_fixture_source
    messages = []
    subscriber = log_subscriber_double(messages)
    event = Struct.new(:payload).new(
      {
        controller: 'ActionMailbox::Ingresses::Ses::InboundEmailsController',
        action: 'create',
        status: 204,
        path: '/rails/action_mailbox/ses/inbound_emails',
        params: { 'Message' => source },
        headers: {}
      }
    )

    begin
      Toybaco::InboundEmail.store_ses_route_token(source)
      subscriber.process_action(event)
    ensure
      Toybaco::InboundEmail.clear_ses_route_token
    end

    completed = messages.find { |entry| entry.include?('Completed 204') }
    refute_nil completed
    line = messages.find { |entry| entry.include?('toybaco-route-log') }
    assert_same_line_route_contract(line, token: 'cafef00d')
    assert_includes line, 'toybaco-fixture-'
  end

  def test_log_subscriber_start_processing_emits_route_log_before_completed
    source = shop1_fixture_source
    messages = []
    subscriber = log_subscriber_double(messages)
    event = Struct.new(:payload).new(
      {
        controller: 'ses/inbound_emails',
        action: 'create',
        path: '/ses/inbound_emails',
        params: { 'Message' => source },
        headers: {}
      }
    )

    begin
      Toybaco::InboundEmail.store_ses_route_token(source)
      subscriber.start_processing(event)
    ensure
      Toybaco::InboundEmail.clear_ses_route_token
    end

    line = messages.find { |entry| entry.include?('toybaco-route-log') }
    assert_same_line_route_contract(line, token: 'cafef00d')
  end

  def test_lograge_subscriber_emits_route_log_on_ses_create_204
    source = shop1_fixture_source
    messages = []
    logger = Object.new
    logger.define_singleton_method(:info) { |msg = nil, &block| messages << (block ? block.call : msg).to_s }
    subscriber = Class.new do
      def initialize(logger)
        @logger = logger
      end

      def logger
        @logger
      end

      def process_action(_event)
        logger.info('{"method":"POST","status":204}')
      end

      prepend Toybaco::InboundEmail::SesIngressLogrageSubscriber
    end.new(logger)
    event = Struct.new(:payload).new(
      {
        controller: 'action_mailbox/ingresses/ses/inbound_emails',
        action: 'create',
        status: 204,
        path: '/rails/action_mailbox/ses/inbound_emails',
        params: { 'Message' => source },
        headers: {}
      }
    )

    begin
      Toybaco::InboundEmail.store_ses_route_token(source)
      subscriber.process_action(event)
    ensure
      Toybaco::InboundEmail.clear_ses_route_token
    end

    assert(messages.any? { |entry| entry.include?('"status":204') })
    line = messages.find { |entry| entry.include?('toybaco-route-log') }
    assert_same_line_route_contract(line, token: 'cafef00d')
  end

  def test_boot_banner_emits_unique_hooks_loaded_substring
    Toybaco::InboundEmail.instance_variable_set(:@inbound_hooks_loaded_banner_emitted, false)
    out = capture_io { Toybaco::InboundEmail.emit_inbound_hooks_loaded_banner! }.first
    line = out.each_line.map(&:chomp).find { |entry| entry.include?('toybaco-inbound-hooks-loaded') }

    refute_nil line
    assert_includes line, 'toybaco-inbound-hooks-loaded=e148640e9ee1'
    refute_includes line, "\n"
    refute_match(/SubscribeURL|conversation_id=\d+/, line)
  end

  def test_middleware_stores_fixture_token_without_puts
    source = shop1_fixture_source
    seen = nil
    app = lambda do |_env|
      seen = Toybaco::InboundEmail.stored_ses_route_token
      [204, {}, []]
    end
    middleware = Toybaco::InboundEmail::SesInboundRouteMiddleware.new(app)
    env = {
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO' => Toybaco::InboundEmail::INGRESS_PATH,
      'rack.input' => StringIO.new(source)
    }

    stdout, = capture_io { middleware.call(env) }

    assert_includes seen, 'toybaco-fixture-cafef00d'
    refute_includes stdout, 'toybaco-route-log'
    assert_nil Thread.current[:toybaco_ses_route_raw]
  end

  def test_reapply_wrappers_installs_log_subscriber_hook
    hook_path = overlay_app_file('lib/toybaco/inbound_email/ses_ingress_reload_hook.rb')
    skip 'SES reload hook overlay はこの品質スナップショットに含まれない' unless File.file?(hook_path)

    hook_source = File.read(hook_path)
    process_path = overlay_app_file('lib/toybaco/inbound_email/ses_ingress_process_action.rb')
    process_source = File.read(process_path)
    subscriber_path = overlay_app_file('lib/toybaco/inbound_email/ses_ingress_log_subscriber.rb')
    subscriber_source = File.read(subscriber_path)

    assert_includes hook_source, 'Toybaco::InboundEmail.install_ses_log_subscriber_hook!'
    assert_includes hook_source, 'Toybaco::InboundEmail.install_ses_lograge_hook!'
    assert_includes process_source, 'ActionController::LogSubscriber'
    assert_includes process_source, 'install_ses_lograge_hook!'
    assert_includes process_source, 'prepend'
    assert_includes process_source, 'store_ses_route_token'
    refute_includes process_source, 'ActiveSupport::Notifications.subscribe'
    refute_includes process_source, 'Event.new(*args)'
    refute_includes process_source, 'prepend_before_action'
    assert_includes subscriber_source, 'def start_processing(event)'
    assert_includes subscriber_source, 'def process_action(event)'
    assert_includes subscriber_source, 'emit_ses_route_from_process_action'
  end

  def test_reloader_to_prepare_calls_explicit_inbound_email_receiver
    hook_path = overlay_app_file('lib/toybaco/inbound_email/ses_ingress_reload_hook.rb')
    skip 'SES reload hook overlay はこの品質スナップショットに含まれない' unless File.file?(hook_path)

    hook_source = File.read(hook_path)

    assert_includes hook_source, 'ActiveSupport::Reloader.to_prepare'
    assert_includes hook_source, 'Toybaco::InboundEmail.reapply_ses_ingress_wrappers!'
    refute_match(
      /ActiveSupport::Reloader\.to_prepare\s*\{\s*reapply_ses_ingress_wrappers!/,
      hook_source,
      'Reloader.to_prepare must not call a bare method (instance_exec binding)'
    )
    refute_match(
      /on_load\([^)]+\)\s*\{\s*reapply_ses_ingress_wrappers!/,
      hook_source,
      'Zeitwerk on_load must not call a bare method (instance_exec binding)'
    )
  end

  def test_reloader_block_survives_instance_eval_on_unrelated_receiver
    captured = nil
    reloader = Module.new do
      define_singleton_method(:to_prepare) { |*_args, &block| captured = block }
    end
    hide = Object.const_defined?(:ActiveSupport)
    previous = Object.const_get(:ActiveSupport) if hide
    support = Module.new
    support.const_set(:Reloader, reloader)
    Object.send(:remove_const, :ActiveSupport) if hide
    Object.const_set(:ActiveSupport, support)
    Toybaco::InboundEmail.instance_variable_set(:@ses_reloader_hook_registered, false)
    begin
      Toybaco::InboundEmail.register_ses_reloader_hook!
      refute_nil captured, 'Reloader.to_prepare must receive a block'
      Object.new.instance_eval(&captured)
    ensure
      Object.send(:remove_const, :ActiveSupport)
      Object.const_set(:ActiveSupport, previous) if hide
      Toybaco::InboundEmail.instance_variable_set(:@ses_reloader_hook_registered, false)
    end
  end

  def test_boot_does_not_emit_controller_missing_from_create_hook
    routing_path = overlay_app_file('lib/toybaco/inbound_email/routing_hooks.rb')
    skip 'routing overlay はこの品質スナップショットに含まれない' unless File.file?(routing_path)

    routing_source = File.read(routing_path)
    hook = routing_source[/def install_ses_ingress_create_hook!\n.*?\n      end\n\n      def install_routing_job_hook!/m]

    refute_nil hook
    refute_includes hook, 'controller_missing',
                    'install_ses_ingress_create_hook! must not abort boot when gem class is still unloaded'
    assert_includes routing_source, 'def warn_unless_ses_controller_loaded!'

    initializer_path = overlay_app_file('config/initializers/toybaco_inbound_email.rb')
    skip 'Chatwoot overlay initializer はこの品質スナップショットに含まれない' unless
      File.file?(initializer_path)

    initializer = File.read(initializer_path)
    assert_includes initializer, 'warn_unless_ses_controller_loaded!'
    assert_includes initializer, 'config.after_initialize'
  end

  def test_ses_inbound_middleware_emits_filter_pattern_on_204
    require_relative '../overlay/app/lib/toybaco/inbound_email/ses_inbound_route_middleware'

    source = shop1_fixture_source
    seen = capture_middleware_store(
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO' => Toybaco::InboundEmail::INGRESS_PATH,
      'rack.input' => StringIO.new(source)
    )

    assert_includes seen[:token], 'toybaco-fixture-cafef00d'
    refute_includes seen[:stdout], 'toybaco-route-log'
  end

  def test_ses_inbound_middleware_matches_script_name_engine_path
    require_relative '../overlay/app/lib/toybaco/inbound_email/ses_inbound_route_middleware'

    source = shop1_fixture_source
    seen = capture_middleware_store(
      'REQUEST_METHOD' => 'POST',
      'SCRIPT_NAME' => Toybaco::InboundEmail::INGRESS_SCOPE,
      'PATH_INFO' => Toybaco::InboundEmail::INGRESS_ROUTE_PATH,
      'rack.input' => StringIO.new(source)
    )

    assert_includes seen[:token], 'toybaco-fixture-cafef00d'
    refute_includes seen[:stdout], 'toybaco-route-log'
  end

  def test_ses_inbound_middleware_reads_header_token_without_body
    require_relative '../overlay/app/lib/toybaco/inbound_email/ses_inbound_route_middleware'

    seen = capture_middleware_store(
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO' => Toybaco::InboundEmail::INGRESS_PATH,
      'HTTP_X_TOYBACO_FIXTURE' => 'toybaco-fixture-cafef00d',
      'rack.input' => StringIO.new('')
    )

    assert_includes seen[:token], 'toybaco-fixture-cafef00d'
    refute_includes seen[:stdout], 'toybaco-route-log'
  end

  def test_ses_inbound_middleware_recovers_raw_post_after_consumed_input
    require_relative '../overlay/app/lib/toybaco/inbound_email/ses_inbound_route_middleware'

    source = shop1_fixture_source
    consumed = Object.new
    consumed.define_singleton_method(:read) { '' }
    seen = capture_middleware_store(
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO' => Toybaco::InboundEmail::INGRESS_PATH,
      'RAW_POST_DATA' => source,
      'rack.input' => consumed
    )

    assert_includes seen[:token], 'toybaco-fixture-cafef00d'
    refute_includes seen[:stdout], 'toybaco-route-log'
  end

  def test_routing_job_hook_emits_filter_pattern_line
    source = [
      'From: Fixture Sender <fixture-sender@example.invalid>',
      'To: shop-1@inbox.staging.toybaco.jp',
      'Delivered-To: shop-1@inbox.staging.toybaco.jp',
      'X-Original-To: shop-1@inbox.staging.toybaco.jp',
      'Subject: toybaco inbound fixture',
      'Message-ID: <rewritten@unknown.host>',
      'X-Toybaco-Fixture: toybaco-fixture-cafef00d',
      '',
      'fixture'
    ].join("\r\n")
    job = Class.new do
      prepend Toybaco::InboundEmail::RoutingHooks::RoutingJobRouteLog

      def perform(_inbound_email)
        true
      end
    end.new
    inbound = Struct.new(:source).new(source)

    out = capture_io { job.perform(inbound) }.first
    line = out.each_line.map(&:chomp).find { |entry| entry.include?('mailbox=SupportMailbox') }

    assert_same_line_route_contract(line, token: 'cafef00d')
    assert_includes line, 'toybaco-route-log'
  end

  def test_ses_create_204_hook_emits_filter_pattern_line
    source = [
      'From: Fixture Sender <fixture-sender@example.invalid>',
      'To: shop-1@inbox.staging.toybaco.jp',
      'Delivered-To: shop-1@inbox.staging.toybaco.jp',
      'X-Original-To: shop-1@inbox.staging.toybaco.jp',
      'Subject: toybaco inbound fixture',
      'Message-ID: <rewritten@unknown.host>',
      'X-Toybaco-Fixture: toybaco-fixture-cafef00d',
      '',
      'fixture'
    ].join("\r\n")
    controller = Class.new do
      prepend Toybaco::InboundEmail::RoutingHooks::SesCreateRouteLog

      def initialize(raw)
        @raw = raw
      end

      def create
        true
      end

      def response
        Struct.new(:status).new(204)
      end

      def notification
        Struct.new(:message_content).new(@raw)
      end

      def request
        Struct.new(:raw_post).new(@raw)
      end
    end.new(source)

    out = capture_io { controller.create }.first
    line = out.each_line.map(&:chomp).find { |entry| entry.include?('mailbox=SupportMailbox') }

    assert_same_line_route_contract(line, token: 'cafef00d')
  end

  def test_support_mailbox_process_logs_fixture_token_on_same_line
    mailbox_path = File.expand_path('../overlay/app/app/mailboxes/support_mailbox.rb', __dir__)
    skip 'SupportMailbox overlay はこの品質スナップショットに含まれない' unless File.file?(mailbox_path)

    stub_reply_mailbox!
    messages = []
    stub_rails_logger!(messages)
    load mailbox_path unless support_mailbox_process_ready?

    source = [
      'From: Fixture Sender <fixture-sender@example.invalid>',
      'To: shop-1@inbox.staging.toybaco.jp',
      'Message-ID: <rewritten@unknown.host>',
      'X-Toybaco-Fixture: toybaco-fixture-cafef00d',
      '',
      'fixture'
    ].join("\r\n")
    mailbox = SupportMailbox.allocate
    mailbox.mail = { message_id: '<rewritten@unknown.host>', raw_source: source }
    mailbox.conversation = nil
    mailbox.inbound_email = Struct.new(:source).new(source)
    capture_io { mailbox.perform_processing }

    line = messages.find { |entry| entry.include?('mailbox=SupportMailbox') }
    assert_same_line_route_contract(line, token: 'cafef00d')
  end

  def test_route_message_id_prefers_raw_fixture_message_id
    mail = {
      message_id: '<rewritten@unknown.host>',
      raw_source: "Message-ID: <toybaco-fixture-cafef00d@inbox.staging.toybaco.jp>\r\n\r\nfixture"
    }

    assert_equal(
      '<toybaco-fixture-cafef00d@inbox.staging.toybaco.jp>',
      Toybaco::InboundEmail.route_message_id(mail)
    )
    assert_equal 'cafef00d', Toybaco::InboundEmail.fixture_token(mail[:raw_source])
  end

  def test_sync_channel_addresses_sets_email_and_forward_to_email
    channel = StubChannel.new(email: 'old@inbox.staging.toybaco.jp', forward_to_email: 'aabbcc@inbox.staging.toybaco.jp')

    Toybaco::InboundEmail.sync_channel_addresses!(channel, 'shop-1@inbox.staging.toybaco.jp')

    assert_equal 'shop-1@inbox.staging.toybaco.jp', channel.email
    assert_equal 'shop-1@inbox.staging.toybaco.jp', channel.forward_to_email
  end

  def test_provision_create_channel_sets_forward_to_email
    source = File.read(File.expand_path('../overlay/app/lib/toybaco/inbound_email.rb', __dir__))

    assert_includes source, 'forward_to_email: address'
    assert_includes source, 'sync_channel_addresses!'
    assert_includes source, 'lower(forward_to_email)'
  end

  def test_overlay_restores_support_mailbox_route
    mailbox_root = File.expand_path('../overlay/app/app/mailboxes', __dir__)
    application = File.join(mailbox_root, 'application_mailbox.rb')
    support = File.join(mailbox_root, 'support_mailbox.rb')
    default_mailbox = File.join(mailbox_root, 'default_mailbox.rb')
    skip 'Chatwoot overlay mailbox はこの品質スナップショットに含まれない' unless
      File.file?(application) && File.file?(support) && File.file?(default_mailbox)

    application_source = File.read(application)
    support_source = File.read(support)
    default_source = File.read(default_mailbox)

    assert_includes application_source, '=> :support'
    assert_includes application_source, 'EmailChannelFinder'
    assert_includes application_source, 'mailbox_route'
    assert_includes application_source, 'log_mailbox_route'
    assert_includes application_source, 'emit_cloudwatch_line'
    assert_includes application_source, '@toybaco_mailbox_route'
    assert_includes application_source, 'inbound_email_raw'
    assert_includes support_source, 'class SupportMailbox < ReplyMailbox'
    assert_includes support_source, 'mailbox: \'SupportMailbox\''
    assert_includes support_source, 'perform_processing'
    assert_includes support_source, 'inbound_email.source'
    assert_includes support_source, 'ensure'
    assert_includes support_source, 'log_mailbox_route'
    assert_includes support_source, 'emit_cloudwatch_line'
    assert_includes default_source, 'class DefaultMailbox'
    assert_includes default_source, 'mailbox: \'DefaultMailbox\''
    refute_match(/SubscribeURL|conversation_id=\d+/, application_source + support_source + default_source)

    routing_dir = File.expand_path('../overlay/app/lib/toybaco/inbound_email', __dir__)
    routing = File.join(routing_dir, 'routing.rb')
    skip 'routing overlay はこの品質スナップショットに含まれない' unless File.file?(routing)
    routing_source = Dir[File.join(routing_dir, '*.rb')].sort.map { |path| File.read(path) }.join
    assert_includes routing_source, 'Array(@email_object.to)'
    assert_includes routing_source, 'Delivered-To'
    assert_includes routing_source, 'SesSource'
    assert_includes routing_source, 'content_in_s3?'
    assert_includes routing_source, 'normalize_address(value)'
    assert_includes routing_source, 'toybaco-fixture-'
    assert_includes routing_source, 'log_ingress_mailbox_route'
    assert_includes routing_source, 'IngressLogHelpers'
    assert_includes routing_source, 'log_ses_create_route'
    assert_includes routing_source, 'create_and_extract_message_id!'
    assert_includes routing_source, 'install_inbound_email_create_hook!'
    assert_includes routing_source, 'install_ses_ingress_create_hook!'
    assert_includes routing_source, 'install_routing_job_hook!'
    assert_includes routing_source, 'load_ses_ingress_controller!'
    assert_includes routing_source, 'ActionMailbox::RoutingJob'
    assert_includes routing_source, 'SesCreateRouteLog'
    assert_includes routing_source, 'RoutingJobRouteLog'
    assert_includes routing_source, 'class_eval'
    assert_includes routing_source, 'toybaco-ses-route-mismatch'
    assert_includes routing_source, 'routes.prepend'
    assert_includes routing_source, 'SesInboundRouteMiddleware'
    assert_includes routing_source, 'SesIngressReloadHook'
    assert_includes routing_source, 'SesIngressReloadHelpers'
    assert_includes routing_source, 'SesIngressProcessAction'
    assert_includes routing_source, 'SesIngressLogSubscriber'
    assert_includes routing_source, 'SesIngressTokenStore'
    assert_includes routing_source, 'SesIngressLograge'
    assert_includes routing_source, 'SesIngressBoot'
    assert_includes routing_source, 'build_ses_create_route_line'
    assert_includes routing_source, 'ActionController::LogSubscriber'
    assert_includes routing_source, 'Lograge::LogSubscribers::ActionController'
    assert_includes routing_source, 'start_processing'
    assert_includes routing_source, 'toybaco-inbound-hooks-loaded'
    assert_includes routing_source, 'install_ses_log_subscriber_hook!'
    assert_includes routing_source, 'install_ses_lograge_hook!'
    assert_includes routing_source, 'emit_inbound_hooks_loaded_banner!'
    assert_includes routing_source, 'store_ses_route_token'
    assert_includes routing_source, 'ses/inbound_emails'
    refute_includes routing_source, 'ActiveSupport::Notifications.subscribe'
    assert_includes routing_source, 'SesIngressReloadHook::SES_INGRESS_CONTROLLER_NAMES'
    assert_includes routing_source, 'zeitwerk_ses_class_names'
    assert_includes routing_source, 'process_action.action_controller'
    assert_includes routing_source, 'on_load'
    assert_includes routing_source, 'Toybaco::InboundEmail.reapply_ses_ingress_wrappers!'
    assert_includes routing_source, 'warn_unless_ses_controller_loaded!'
    assert_includes routing_source, 'ensure_ses_ingress_route!'
    refute_match(
      /ActiveSupport::Reloader\.to_prepare\s*\{\s*reapply_ses_ingress_wrappers!/,
      routing_source
    )
    assert_includes routing_source, 'SCRIPT_NAME'
    assert_includes routing_source, 'RAW_POST_DATA'
    assert_includes routing_source, 'HTTP_X_TOYBACO_FIXTURE'
    assert_includes routing_source, 'recognize_path'
    assert_includes routing_source, 'toybaco-route-log'
    assert_includes routing_source, '$stdout.puts'
    assert_includes routing_source, 'ActiveJob::Base.logger'
    assert_includes routing_source, 'response&.status == 204'
    refute_includes routing_source, 'malformed_to?'
    hook = routing_source[/def install_ses_ingress_create_hook!\n.*?\n      end\n\n      def install_routing_job_hook!/m]
    refute_nil hook
    refute_includes hook, 'rescue NameError'
    create_hook = routing_source[/def install_inbound_email_create_hook!\n.*?\n      end\n\n      def install_ses_ingress_create_hook!/m]
    refute_nil create_hook
    refute_includes create_hook, 'rescue NameError'
  end

  def assert_same_line_route_contract(log, token:)
    refute_nil log
    assert_includes log, 'toybaco-route-log'
    assert_includes log, 'mailbox=SupportMailbox'
    assert_match(/Conversation=(yes|no)/, log)
    assert_includes log, "toybaco-fixture-#{token}"
    refute_includes log, "\n"
    refute_match(/conversation_id=\d+/, log)
    refute_includes log, 'fixture-sender'
  end

  def overlay_app_file(*relative)
    File.join(File.expand_path('..', __dir__), 'overlay', 'app', *relative)
  end

  def stub_reply_mailbox!
    return if Object.const_defined?(:ReplyMailbox)

    Object.const_set(:ReplyMailbox, Class.new do
      attr_accessor :mail, :conversation, :inbound_email

      def perform_processing
        process
      end

      def process; end
    end)
  end

  def shop1_fixture_source
    [
      'From: Fixture Sender <fixture-sender@example.invalid>',
      'To: shop-1@inbox.staging.toybaco.jp',
      'Delivered-To: shop-1@inbox.staging.toybaco.jp',
      'X-Original-To: shop-1@inbox.staging.toybaco.jp',
      'Subject: toybaco inbound fixture',
      'Message-ID: <rewritten@unknown.host>',
      'X-Toybaco-Fixture: toybaco-fixture-cafef00d',
      '',
      'fixture'
    ].join("\r\n")
  end

  def capture_middleware_store(env)
    seen = nil
    app = lambda do |_env|
      seen = Toybaco::InboundEmail.stored_ses_route_token
      [204, {}, []]
    end
    middleware = Toybaco::InboundEmail::SesInboundRouteMiddleware.new(app)
    stdout, = capture_io { middleware.call(env) }
    { token: seen.to_s, stdout: stdout }
  end

  def log_subscriber_double(messages)
    logger = Object.new
    logger.define_singleton_method(:info) do |msg = nil, &block|
      messages << (block ? block.call : msg).to_s
    end

    Class.new do
      def initialize(logger)
        @logger = logger
      end

      def logger
        @logger
      end

      def info(progname = nil, &block)
        logger.info(progname, &block)
      end

      def start_processing(_event)
        info { 'Started POST' }
      end

      def process_action(event)
        status = event.payload[:status]
        info { "Completed #{status} No Content" }
      end

      prepend Toybaco::InboundEmail::SesIngressLogSubscriber
    end.new(logger)
  end

  def stub_rails_logger!(messages)
    unless defined?(Rails)
      Object.const_set(:Rails, Module.new)
      Rails.singleton_class.attr_accessor :logger
    end
    logger = Object.new
    logger.define_singleton_method(:info) { |msg| messages << msg.to_s }
    Rails.logger = logger
  end

  def support_mailbox_process_ready?
    defined?(SupportMailbox) &&
      SupportMailbox.instance_methods(false).include?(:perform_processing)
  end

  def test_ingest_reads_delivered_to_header
    routed = Toybaco::InboundEmail.route(
      { 'Delivered-To' => ['shop-6@inbox.toybaco.jp'] },
      mailboxes: [{ email: 'shop-6@inbox.toybaco.jp', account_id: 6 }]
    )

    assert_equal :new_conversation, routed[:action]
    assert_equal 'shop-6@inbox.toybaco.jp', routed[:address]
  end

  class StubChannel
    attr_accessor :email, :forward_to_email

    def initialize(email:, forward_to_email:)
      @email = email
      @forward_to_email = forward_to_email
    end

    def update!(attrs)
      @email = attrs[:email] if attrs.key?(:email)
      @forward_to_email = attrs[:forward_to_email] if attrs.key?(:forward_to_email)
    end
  end

  class StubAccount
    attr_reader :id, :internal_attributes

    def initialize(id:)
      @id = id
      @internal_attributes = {}
    end

    def update!(attrs)
      @internal_attributes = attrs.fetch(:internal_attributes)
    end
  end
end
