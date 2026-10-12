# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # 段 2a(2026-10-08 owner 承認): メールの窓口で、一斉配信・自動送信・配信不能の通知・noreply の送り手からのメッセージには、
    # AI が自動で返信しない(窓口の自動応答と growth の Lambda)。手動の返信案は対象外(人が判断する)。取り込み・通知は変えない。
    # 判定はメッセージに保存したメールの情報(content_attributes['email'] の auto_reply・from・content_type・headers)と
    # 送り手のメールアドレスだけで行い、迷ったら返さない側に倒す。上のどれにも当たらない普通のメールは除外しない。
    module AutomatedMail
      REASON = 'automated_mail'
      PRECEDENCE_BULK = %w[bulk list junk].freeze
      BOUNCE_SENDERS = %w[mailer-daemon@ postmaster@].freeze
      NOREPLY = %w[noreply donotreply].freeze
      # 窓口の自動応答が返さずに担当者へ渡すとき、会話に残す内部メモの文言(docs/ux-terms-20261006.md)。
      NOTE_LABELS = {
        'auto_submitted' => '自動送信のメール', 'bulk' => '一斉配信のメール', 'bounce' => '配信不能の通知',
        'noreply' => '返信を受け付けない送信元のメール'
      }.freeze

      module_function

      # 返り値は { 'reason' => 'automated_mail', 'kind' => 'auto_submitted' | 'bulk' | 'bounce' | 'noreply' } か nil。
      def reason(message)
        return unless message&.incoming? && message.inbox&.channel_type == 'Channel::Email'

        email = plain_hash(message.content_attributes&.[]('email'))
        headers = headers(email)
        kind = kind_of(email, headers, senders(message, email, headers))
        { 'reason' => REASON, 'kind' => kind } if kind
      end

      def note(kind)
        "AI返信は自動で送りません: #{NOTE_LABELS.fetch(kind)}と判定(kind: #{kind})"
      end

      def kind_of(email, headers, senders)
        return 'auto_submitted' if auto_submitted?(email, headers)
        return 'bulk' if bulk?(headers)
        return 'bounce' if bounce?(email, headers, senders)

        'noreply' if senders.any? { |address| noreply?(address) }
      end

      # Auto-Submitted が no 以外・X-Autoreply: yes(大小文字を問わない)・X-Auto-Response-Suppress・Precedence: auto_reply。
      def auto_submitted?(email, headers)
        auto_reply?(email, headers) || headers.key?('x-auto-response-suppress') || precedence(headers).include?('auto_reply')
      end

      # Auto-Submitted・X-Autoreply の生値(MailPresenterHeaders が残す)があれば、それを正規化して判定する。upstream の
      # email.auto_reply は 'no' / 'yes' と大小文字まで一致で判定する(Auto-Submitted: No を自動送信、X-Autoreply: YES を
      # 普通のメールとする)ので、生値の無い以前のメッセージにだけ使う。
      def auto_reply?(email, headers)
        return email['auto_reply'] == true unless headers.key?('auto-submitted') || headers.key?('x-autoreply')

        values(headers, 'auto-submitted').any? { |value| value.downcase != 'no' } ||
          values(headers, 'x-autoreply').any? { |value| value.casecmp?('yes') }
      end

      def bulk?(headers)
        headers.key?('list-unsubscribe') || headers.key?('list-id') ||
          precedence(headers).any? { |token| PRECEDENCE_BULK.include?(token) }
      end

      # Precedence は、引用符・括弧・前後の空白を除いた先頭の語(英数字と _ -)を小文字で比べる(例: "bulk"・(list)・Bulk )。
      def precedence(headers)
        values(headers, 'precedence').filter_map { |value| value[/[A-Za-z0-9_-]+/]&.downcase }
      end

      # 送り手が mailer-daemon@ / postmaster@、Return-Path が空(<>)、X-Failed-Recipients がある、本文が配信状況の報告(multipart/report)。
      def bounce?(email, headers, senders)
        senders.any? { |address| address.start_with?(*BOUNCE_SENDERS) } || headers.key?('x-failed-recipients') ||
          values(headers, 'return-path').any? { |value| value.delete(' ').in?(['', '<>']) } ||
          email['content_type'].to_s.strip.downcase.start_with?('multipart/report')
      end

      # ローカル部が noreply・no-reply・donotreply・do-not-reply(大小文字と区切りの - _ . を問わない。+ 以降は見ない)。
      def noreply?(address)
        local = address.split('@').first.to_s.split('+').first.to_s
        NOREPLY.include?(local.delete('-_.'))
      end

      # 送り手: 保存したメールの from(upstream は Reply-To を優先して入れる)、元の From の生値のアドレス(表示名を除く。
      # 複数可。From: no-reply@…、Reply-To: support@… のメールを noreply と見分けるため)、会話の連絡先のメールアドレス。
      def senders(message, email, headers)
        contact = message.sender.respond_to?(:email) ? message.sender.email : nil
        raw = values(headers, 'from').flat_map { |value| header_addresses(value) }
        (Array(email['from']) + raw + [contact]).filter_map { |address| address.to_s.strip.downcase.presence }
      end

      # ヘッダーの値からアドレスだけを取り出す。読めない値は、アドレスの形の部分をすべて拾う(迷ったら返さない側)。
      def header_addresses(value)
        Mail::AddressList.new(value).addresses.filter_map(&:address)
      rescue Mail::Field::ParseError, Mail::Field::IncompleteParseError
        value.scan(/[^\s<>",;]+@[^\s<>",;]+/)
      end

      # ヘッダー名は大小文字を問わない。値は文字列でも配列でもよい。
      def headers(email)
        plain_hash(email['headers']).transform_keys { |name| name.to_s.downcase }
      end

      def values(headers, name)
        return [] unless headers.key?(name)

        Array(headers[name]).map { |value| value.to_s.strip }
      end

      def plain_hash(value)
        value.respond_to?(:to_h) && !value.is_a?(Array) ? value.to_h.stringify_keys : {}
      end
    end
  end
end
