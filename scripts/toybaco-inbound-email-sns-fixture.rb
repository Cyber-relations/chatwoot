#!/usr/bin/env ruby
# frozen_string_literal: true

# SES Received 本文を作り、staging inbound SNS へ Publish するための fixture。
# 署名は AWS SNS だけが付けられる。実メール送信・本番 account は扱わない。

require 'json'
require 'securerandom'
require 'time'
require_relative '../overlay/app/lib/toybaco/inbound_email'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    module SnsFixture
      STAGING_ACCOUNT_ID = '847883042333'
      PRODUCTION_ACCOUNT_ID = '951034765053'
      STAGING_TOPIC_NAME = 'toybaco-staging-inbound-email'
      STAGING_DOMAIN = 'inbox.staging.toybaco.jp'
      STAGING_TOPIC_ARN = "arn:aws:sns:#{TOKYO_REGION}:#{STAGING_ACCOUNT_ID}:#{STAGING_TOPIC_NAME}"
      STAGING_INGRESS_URL = "https://app.staging.toybaco.jp#{INGRESS_PATH}"
      STAGING_DEPLOY_ROLE_ARN = "arn:aws:iam::#{STAGING_ACCOUNT_ID}:role/toybaco-github-deploy-staging"
      TOKEN = /\A[0-9a-f]{8,32}\z/
      STAGING_TOPIC = /\Aarn:aws:sns:ap-northeast-1:847883042333:toybaco-staging-inbound-email\z/
      POLICY_ALLOW_STAGING_DEPLOY = 'ALLOW_STAGING_DEPLOY'
      POLICY_DENIES_STAGING_DEPLOY = 'DENIES_STAGING_DEPLOY'
      POLICY_UNSAFE_PRODUCTION = 'UNSAFE_PRODUCTION'
      POLICY_MISSING_SES = 'MISSING_SES'
      POLICY_WILDCARD_PUBLISH = 'WILDCARD_PUBLISH'
      POLICY_INVALID = 'INVALID_POLICY'

      module_function

      def build(account_id: 1, token: nil, now: Time.now.utc, topic_arn: STAGING_TOPIC_ARN)
        topic = topic_arn.to_s.strip
        raise Rejected, 'SNS トピックが staging inbound ではありません' unless STAGING_TOPIC.match?(topic)
        raise Rejected, '本番 account の fixture は作れません' if topic.include?(PRODUCTION_ACCOUNT_ID)

        domain_env = {
          'MAILER_INBOUND_EMAIL_DOMAIN' => STAGING_DOMAIN,
          'RAILS_INBOUND_EMAIL_SERVICE' => 'ses',
          'ACTION_MAILBOX_SES_SNS_TOPIC' => topic
        }
        destination = InboundEmail.mailbox_address(account_id, domain_env)
        raise Rejected, 'staging inbox 以外へは作れません' unless destination.end_with?("@#{STAGING_DOMAIN}")

        stamp = now.getutc
        fixture_token = normalize_token(token)
        message_id = "<toybaco-fixture-#{fixture_token}@#{STAGING_DOMAIN}>"
        rfc822 = rfc822_message(
          destination: destination,
          message_id: message_id,
          fixture_token: fixture_token,
          date: stamp
        )
        ses = {
          'notificationType' => 'Received',
          'mail' => {
            'timestamp' => stamp.iso8601,
            'source' => 'fixture-sender@example.invalid',
            'messageId' => "toybaco-fixture-#{fixture_token}",
            'destination' => [destination]
          },
          'receipt' => {
            'timestamp' => stamp.iso8601,
            'action' => {
              'type' => 'SNS',
              'topicArn' => topic,
              'encoding' => 'UTF-8'
            }
          },
          'content' => rfc822
        }
        payload = {
          'Type' => 'Notification',
          'MessageId' => "toybaco-sns-#{fixture_token}",
          'Timestamp' => stamp.iso8601,
          'TopicArn' => topic,
          'Message' => JSON.generate(ses),
          'SignatureVersion' => '1',
          'Signature' => 'unsigned-toybaco-inbound-fixture',
          'SigningCertURL' => 'https://example.invalid/toybaco-inbound-fixture.pem',
          'UnsubscribeURL' => 'https://example.invalid/?Action=Unsubscribe'
        }
        {
          payload: payload,
          ses: ses,
          token: fixture_token,
          destination: destination,
          message_id: payload['MessageId']
        }
      end

      def write!(path = nil, ses_path: nil, **kwargs)
        built = build(**kwargs)
        File.write(path, "#{JSON.generate(built.fetch(:payload))}\n") if path && !path.to_s.empty?
        File.write(ses_path, "#{JSON.generate(built.fetch(:ses))}\n") if ses_path && !ses_path.to_s.empty?
        built
      end

      # live topic policy を fail-closed で分類する。本文・ARN は返さない。
      def topic_policy_verdict(raw)
        document = policy_document_of(raw)
        statements = Array(document['Statement'])
        return POLICY_INVALID if statements.empty?

        publish_statements = statements.select { |statement| allows_publish?(statement) }
        return POLICY_INVALID if publish_statements.empty?

        principals = publish_statements.flat_map { |statement| principals_of(statement) }
        return POLICY_WILDCARD_PUBLISH if principals.any? { |entry| entry[:type] == :wildcard }
        return POLICY_UNSAFE_PRODUCTION if principals.any? { |entry| production_principal?(entry) }
        return POLICY_MISSING_SES unless publish_statements.any? { |statement| ses_publish?(statement) }
        return POLICY_ALLOW_STAGING_DEPLOY if publish_statements.any? { |statement| staging_deploy_publish?(statement) }

        POLICY_DENIES_STAGING_DEPLOY
      rescue JSON::ParserError, TypeError, KeyError
        POLICY_INVALID
      end

      def destinations_of(payload)
        InboundEmail.destinations_for(received_notification(payload))
      end

      # aws-actionmailbox-ses 0.1.0 SNSNotification#message_content と同じ形。
      # S3 action は触れない。本文は呼び出し側が出さない。
      def action_mailbox_source(payload)
        notification = received_notification(payload)
        action = notification.dig('receipt', 'action')
        raise Rejected, 'S3 原本参照は fixture 対象外です' if action.is_a?(Hash) && action['type'] == 'S3'

        content = notification['content'].to_s
        raise Rejected, 'RFC822 content がありません' if content.empty?

        destination = Array(notification.dig('mail', 'destination')).first
        InboundEmail.ses_action_mailbox_source(content: content, destination: destination)
      end

      def policy_document_of(raw)
        parsed = raw.is_a?(String) ? JSON.parse(raw) : raw
        if parsed.is_a?(Hash) && parsed['Attributes'].is_a?(Hash)
          parsed = JSON.parse(parsed['Attributes'].fetch('Policy'))
        elsif parsed.is_a?(Hash) && parsed['Policy'].is_a?(String)
          parsed = JSON.parse(parsed['Policy'])
        end
        raise TypeError unless parsed.is_a?(Hash) && parsed['Statement']

        parsed
      end
      private_class_method :policy_document_of

      def allows_publish?(statement)
        return false unless statement.is_a?(Hash)
        return false unless statement['Effect'].to_s == 'Allow'

        Array(statement['Action']).map(&:to_s).any? { |action| action == 'sns:Publish' || action == 'sns:*' || action == '*' }
      end
      private_class_method :allows_publish?

      def principals_of(statement)
        principal = statement['Principal']
        case principal
        when '*'
          [{ type: :wildcard, value: '*' }]
        when String
          [principal_entry(principal)]
        when Hash
          list = []
          Array(principal['AWS']).each { |value| list << principal_entry(value) }
          Array(principal['Service']).each { |value| list << { type: :service, value: value.to_s } }
          list << { type: :wildcard, value: '*' } if principal.key?('*')
          list
        else
          []
        end
      end
      private_class_method :principals_of

      def principal_entry(value)
        text = value.to_s
        return { type: :wildcard, value: '*' } if text == '*'

        { type: :aws, value: text }
      end
      private_class_method :principal_entry

      def production_principal?(entry)
        entry[:type] == :aws && entry[:value].include?(PRODUCTION_ACCOUNT_ID)
      end
      private_class_method :production_principal?

      def ses_publish?(statement)
        principals_of(statement).any? { |entry| entry[:type] == :service && entry[:value] == 'ses.amazonaws.com' }
      end
      private_class_method :ses_publish?

      def staging_deploy_publish?(statement)
        principals = principals_of(statement)
        return false if principals.empty?
        return false unless principals.all? { |entry| entry[:type] == :aws && entry[:value] == STAGING_DEPLOY_ROLE_ARN }

        true
      end
      private_class_method :staging_deploy_publish?

      def received_notification(payload)
        unwrapped = InboundEmail.unwrap_sns(payload)
        raise Rejected, 'Notification ではありません' unless unwrapped[:kind] == :received

        notification = unwrapped.fetch(:notification)
        raise Rejected, 'SES Received ではありません' unless notification['notificationType'] == 'Received'

        notification
      end
      private_class_method :received_notification

      def normalize_token(token)
        value = token.to_s.strip
        value = SecureRandom.hex(8) if value.empty?
        raise Rejected, 'fixture token が不正です' unless TOKEN.match?(value)

        value
      end

      def rfc822_message(destination:, message_id:, fixture_token:, date:)
        [
          'From: Fixture Sender <fixture-sender@example.invalid>',
          "To: #{destination}",
          "Delivered-To: #{destination}",
          "X-Original-To: #{destination}",
          'Subject: toybaco inbound fixture',
          "Message-ID: #{message_id}",
          "X-Toybaco-Fixture: toybaco-fixture-#{fixture_token}",
          "Date: #{date.httpdate}",
          'MIME-Version: 1.0',
          'Content-Type: text/plain; charset=UTF-8',
          'Content-Transfer-Encoding: 7bit',
          '',
          'fixture'
        ].join("\r\n")
      end
      private_class_method :rfc822_message
    end
  end
end

if $PROGRAM_NAME == __FILE__
  require 'optparse'

  begin
    options = {
      account_id: 1,
      token: nil,
      topic_arn: Toybaco::InboundEmail::SnsFixture::STAGING_TOPIC_ARN,
      output: nil,
      ses_output: nil,
      policy_file: nil
    }
    OptionParser.new do |parser|
      parser.banner = 'Usage: toybaco-inbound-email-sns-fixture.rb --ses-output PATH'
      parser.on('--account-id ID', Integer) { |value| options[:account_id] = value }
      parser.on('--token TOKEN') { |value| options[:token] = value }
      parser.on('--topic-arn ARN') { |value| options[:topic_arn] = value }
      parser.on('--output PATH') { |value| options[:output] = value }
      parser.on('--ses-output PATH') { |value| options[:ses_output] = value }
      parser.on('--policy-file PATH') { |value| options[:policy_file] = value }
    end.parse!

    policy_file = options[:policy_file].to_s
    unless policy_file.empty?
      abort '本番向け policy は読めません' if policy_file.include?(Toybaco::InboundEmail::SnsFixture::PRODUCTION_ACCOUNT_ID)
      verdict = Toybaco::InboundEmail::SnsFixture.topic_policy_verdict(File.read(policy_file))
      STDOUT.puts("policy=#{verdict}")
      exit 0
    end

    output = options[:output].to_s
    ses_output = options[:ses_output].to_s
    abort 'output がありません' if output.empty? && ses_output.empty?
    abort '本番向け output は書けません' if output.include?(Toybaco::InboundEmail::SnsFixture::PRODUCTION_ACCOUNT_ID)
    abort '本番向け output は書けません' if ses_output.include?(Toybaco::InboundEmail::SnsFixture::PRODUCTION_ACCOUNT_ID)

    receipt = Toybaco::InboundEmail::SnsFixture.write!(
      output.empty? ? nil : output,
      ses_path: ses_output.empty? ? nil : ses_output,
      account_id: options.fetch(:account_id),
      token: options[:token],
      topic_arn: options.fetch(:topic_arn)
    )
    # 本文・ARN・宛先は出さない。token は PII ではない。
    STDOUT.puts("token=#{receipt.fetch(:token)}")
    STDOUT.puts('account=staging')
    STDOUT.puts('kind=Notification')
  rescue Toybaco::InboundEmail::Rejected => error
    warn error.message
    exit 1
  end
end
