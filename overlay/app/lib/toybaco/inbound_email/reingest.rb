# frozen_string_literal: true

require 'digest'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # DLQ に入った受信(SNS → ActionMailbox SES ingress の配送の失敗)を、S3 の原本 inbound/<SES の messageId> から取り込み直す
    # (rake toybaco:inbound_email_reingest、docs/inbound-email.md の「配送の再試行・DLQ・再投入」)。
    # 取り込みは SES ingress の create と同じ ActionMailbox::InboundEmail.create_and_extract_message_id! で、原本の前に受信の宛先を
    # X-Original-To / Delivered-To で載せる(ses_action_mailbox_source)。経路(ApplicationMailbox の SupportMailbox / ReplyMailbox /
    # DefaultMailbox)、会話の作成、経路ログは通常の受信と同じ routing job が行う。
    # ingress と違い SNS の署名も通知の宛先も無いので、ActionMailbox へ渡す前に次で止める(どれも何も書かない)。
    # - messageId は SES の形(英小文字・数字の 20〜64 字)だけ。prefix の外の key・SES の設定確認の object・path を読まない
    # - 受信 ENV が SES ingress の形でない環境、bucket の名前が受信の bucket の形でない環境
    # - 原本が無い(期限切れの削除マーカーを含む)は not_found。40 MB(SES の受信の上限)を超える・Message-ID が無いものは rejected
    # - DefaultMailbox に落ちる宛先(どの受信箱にも一致しない)は rejected
    # - 宛先の受信箱に同じ Message-ID の Message があるか、その受信箱へ載る処理中の ActionMailbox の行がある(会話を二重に作らない)
    #   は duplicate。宛先の受信箱へ載る行が処理済みか古いまま残り、Message が無いのは stranded(ReingestDelivery)。重複は先に
    #   宛先の受信箱を決めてから、その受信箱に限って見る。別の店舗の受信箱に同じ Message-ID が着地済みでも(同じメールの複数の
    #   店舗への転送など)、この受信箱へは取り込む。
    # 宛先は原本の先頭の Received(SES が足す by inbound-smtp.<東京> の行)の for だけから取り、受信ドメインの宛先に限る。それより
    # 下の Received は送信者が書けるので読まない。for が無ければ宛先を足さず、To / Cc などで判定する。
    # 出力は固定語の 1 行だけ(原本・宛先・件名・Message-ID は出さない)。
    module Reingest
      PREFIX = 'TOYBACO_INBOUND_REINGEST'
      MESSAGE_ID = /\A[a-z0-9]{20,64}\z/
      BUCKET = /\A[a-z0-9][a-z0-9-]{0,40}-inbound-email\z/
      KEY_PREFIX = 'inbound/'
      MAX_BYTES = 40 * 1024 * 1024
      SES_RECEIVED = /\bby\s+inbound-smtp\.ap-northeast-1\.amazonaws\.com\b/i
      RECEIVED_FOR = /\bfor\s+<?([^\s<>;]+@[^\s<>;]+?)>?\s*;/i
      SUCCESS = %w[ingested duplicate].freeze

      class Stop < StandardError
        attr_reader :result

        def initialize(result)
          @result = result
          super(result)
        end
      end

      module_function

      def line(result, message_id)
        "#{PREFIX} result=#{result} key=#{::Digest::SHA256.hexdigest(message_id.to_s)[0, 12]}"
      end

      # 結果の語(ingested / duplicate / stranded / not_found / rejected / failed)を返す。例外の文は出さない。
      def run(message_id, environment: ENV, client: nil)
        id = message_id.to_s
        raise Stop, 'rejected' unless MESSAGE_ID.match?(id)

        bucket = environment['TOYBACO_INBOUND_EMAIL_BUCKET'].to_s
        raise Stop, 'rejected' unless InboundEmail.ingress_enabled?(environment) && BUCKET.match?(bucket)

        raw = fetch(client || ::Aws::S3::Client.new(region: InboundEmail::TOKYO_REGION), bucket, id)
        ingest(raw, InboundEmail.config(environment).domain)
      rescue Stop => e
        e.result
      rescue StandardError
        'failed'
      end

      def fetch(client, bucket, id)
        object = client.get_object(bucket: bucket, key: "#{KEY_PREFIX}#{id}")
        raise Stop, 'rejected' if object.content_length.to_i > MAX_BYTES

        raw = object.body.read.b
        raise Stop, 'rejected' if raw.empty? || raw.bytesize > MAX_BYTES

        raw
      rescue ::Aws::S3::Errors::NoSuchKey
        raise Stop, 'not_found'
      end

      def ingest(raw, domain)
        source = InboundEmail.ses_action_mailbox_source(content: raw, destination: envelope_destination(raw, domain).to_s)
        mail = ::Mail.from_source(source)
        message_id = mail.message_id.to_s
        raise Stop, 'rejected' if message_id.empty?

        route = ::ApplicationMailbox.toybaco_resolve_route(mail)
        raise Stop, 'rejected' if route == :default

        ReingestDelivery.ingest(source, message_id, DeliveryDestination.inbox(mail, route))
      end

      # SES が先頭に足す Received の for。受信ドメインの宛先だけを返す(無ければ nil)。
      def envelope_destination(raw, domain)
        received = first_header(raw, 'Received')
        return unless received&.match?(SES_RECEIVED)

        address = InboundEmail.normalize_address(received[RECEIVED_FOR, 1])
        address if !domain.to_s.empty? && address.end_with?("@#{domain}")
      end

      # header 部(最初の空行まで)の、折り返しを戻した最初の name の値。
      def first_header(raw, name)
        headers = []
        raw.each_line do |row|
          break if row.strip.empty?

          if row.start_with?(' ', "\t") && headers.any?
            headers[-1] = "#{headers[-1]} #{row.strip}"
          else
            headers << row.strip
          end
        end
        field, value = headers.map { |header| header.split(':', 2) }.find { |key, _| key.to_s.strip.casecmp?(name) }
        value.to_s.strip if field
      end
    end
  end
end
