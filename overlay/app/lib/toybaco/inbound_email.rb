# frozen_string_literal: true

require_relative 'inbound_email/readiness'
require_relative 'inbound_email/ingest'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # SES inbound (ap-northeast-1) → Chatwoot Channel::Email の契約。
  # MX / ドメイン / ingress が揃うまで受信箱を作らず、未知宛先は拒否する(握りつぶさない)。
  module InboundEmail
    TOKYO_REGION = 'ap-northeast-1'
    TOKYO_MX = 'inbound-smtp.ap-northeast-1.amazonaws.com'
    INGRESS_PATH = '/rails/action_mailbox/ses/inbound_emails'
    INGRESS_SCOPE = '/rails/action_mailbox'
    INGRESS_MODULE = 'action_mailbox/ingresses'
    INGRESS_ROUTE_PATH = '/ses/inbound_emails'
    INGRESS_TO = 'ses/inbound_emails#create'
    INGRESS_AS = :toybaco_rails_ses_inbound_emails
    INGRESS_GET_TO = 'toybaco/inbound_email_ingress#method_not_allowed'
    INGRESS_GET_AS = :toybaco_rails_ses_inbound_emails_get
    ALLOWED_INGRESS_STATUSES = [400, 401, 403, 405, 415, 422].freeze
    INBOX_NAME = 'メール'
    LOCAL_PART_PREFIX = 'shop'
    ATTR_KEY = 'toybaco_inbound_email'
    ALLOWED_DOMAINS = %w[inbox.toybaco.jp inbox.staging.toybaco.jp].freeze
    REPLY_LOCAL_PART = /\Areply\+([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z/i
    SNS_TOPIC = /\Aarn:aws:sns:ap-northeast-1:\d{12}:[A-Za-z0-9_-]+\z/
    MAILBOX_EMAIL = /\A[a-z0-9][a-z0-9.+_-]*@[a-z0-9.-]+\z/i

    class NotReady < StandardError; end
    class Rejected < StandardError; end

    Config = Struct.new(:domain, :service, :sns_topic, :expected_mx, :region, keyword_init: true)

    extend Readiness
    extend Ingest

    module_function

    def config(environment = ENV)
      Config.new(
        domain: fetch_stripped(environment, 'MAILER_INBOUND_EMAIL_DOMAIN'),
        service: fetch_stripped(environment, 'RAILS_INBOUND_EMAIL_SERVICE'),
        sns_topic: fetch_stripped(environment, 'ACTION_MAILBOX_SES_SNS_TOPIC'),
        expected_mx: present_or(environment, 'TOYBACO_INBOUND_EMAIL_MX', TOKYO_MX),
        region: present_or(environment, 'TOYBACO_INBOUND_EMAIL_REGION', TOKYO_REGION)
      )
    end

    def provision!(account, environment: ENV, resolver: nil, factory: nil)
      status = readiness(environment, resolver: resolver)
      unless status[:ready]
        remember(account, 'status' => 'blocked', 'reasons' => status[:reasons])
        raise NotReady, status[:reasons].join(' / ')
      end

      address = mailbox_address(account.id, environment)
      created = (factory || method(:create_channel!)).call(account, address)
      remember(
        account,
        'status' => 'ready',
        'address' => address,
        'inbox_name' => INBOX_NAME,
        'ingress' => INGRESS_PATH
      )
      created.merge(address: address)
    end

    def remember(account, payload)
      attrs = account.internal_attributes || {}
      account.update!(internal_attributes: attrs.merge(ATTR_KEY => payload))
    end
    private_class_method :remember

    def create_channel!(account, address)
      existing = Channel::Email.find_by('lower(email) = ?', address)
      if existing
        raise NotReady, 'この受信アドレスは別アカウントで使われています' unless existing.account_id == account.id

        return { channel: existing, inbox: existing.inbox, created: false }
      end

      account.enable_features!('inbound_emails') if account.respond_to?(:enable_features!)
      channel = Channel::Email.create!(account: account, email: address, imap_enabled: false, smtp_enabled: false)
      inbox = Inbox.create!(account: account, name: INBOX_NAME, channel: channel)
      attach_members!(account, inbox)
      { channel: channel, inbox: inbox, created: true }
    end
    private_class_method :create_channel!

    def attach_members!(account, inbox)
      return unless account.respond_to?(:account_users)

      account.account_users.find_each do |membership|
        InboxMember.find_or_create_by!(inbox_id: inbox.id, user_id: membership.user_id)
      end
    end
    private_class_method :attach_members!

    def fetch_stripped(environment, key)
      environment[key].to_s.strip
    end
    private_class_method :fetch_stripped

    def present_or(environment, key, fallback)
      value = environment[key].to_s.strip
      value.empty? ? fallback : value
    end
    private_class_method :present_or
  end
end
