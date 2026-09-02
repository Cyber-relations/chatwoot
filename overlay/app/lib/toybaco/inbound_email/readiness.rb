# frozen_string_literal: true

require 'resolv'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # MX / ドメイン / SES ingress が揃っているか。欠けていれば受信箱を作らない。
    module Readiness
      def readiness(environment = ENV, resolver: nil)
        cfg = InboundEmail.config(environment)
        reasons = config_reasons(cfg)
        reasons.concat(mx_reasons(cfg, resolver)) if reasons.empty?
        { ready: reasons.empty?, reasons: reasons, config: cfg }
      end

      def ready?(environment = ENV, resolver: nil)
        readiness(environment, resolver: resolver).fetch(:ready)
      end

      # MX は受信箱作成の判定。ルート描画は受信 ENV 3 鍵だけで決める。
      def ingress_enabled?(environment = ENV)
        cfg = InboundEmail.config(environment)
        ALLOWED_DOMAINS.include?(cfg.domain) &&
          cfg.service == 'ses' &&
          SNS_TOPIC.match?(cfg.sns_topic)
      end

      def mailbox_address(account_id, environment = ENV)
        cfg = InboundEmail.config(environment)
        raise NotReady, '受信ドメインが未設定です' if cfg.domain.empty?
        raise NotReady, '受信ドメインが許可された inbox サブドメインではありません' unless ALLOWED_DOMAINS.include?(cfg.domain)

        "#{LOCAL_PART_PREFIX}-#{Integer(account_id)}@#{cfg.domain}"
      end

      private

      def config_reasons(cfg)
        reasons = []
        reasons << '受信ドメインが未設定です' if cfg.domain.empty?
        reasons << '受信ドメインが許可された inbox サブドメインではありません' unless ALLOWED_DOMAINS.include?(cfg.domain)
        reasons << '受信サービスが ses ではありません' unless cfg.service == 'ses'
        reasons << 'SNS トピック ARN が東京リージョンの形式ではありません' unless SNS_TOPIC.match?(cfg.sns_topic)
        reasons << '受信 MX が東京の inbound-smtp ではありません' unless cfg.expected_mx == TOKYO_MX
        reasons << '受信リージョンが ap-northeast-1 ではありません' unless cfg.region == TOKYO_REGION
        reasons
      end

      def mx_reasons(cfg, resolver)
        records = Array(resolve_mx(cfg.domain, resolver)).map { |host| host.to_s.downcase.chomp('.') }
        return [] if records.include?(TOKYO_MX)

        ['受信ドメインの MX が東京の inbound-smtp を指していません']
      end

      def resolve_mx(domain, resolver)
        return resolver.records(domain) if resolver

        Resolv::DNS.open do |dns|
          dns.getresources(domain, Resolv::DNS::Resource::IN::MX).map { |mx| mx.exchange.to_s }
        end
      end
    end
  end
end
