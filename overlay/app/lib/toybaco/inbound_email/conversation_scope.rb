# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # 受信メールの会話探し(上流 Chatwoot v4.18.0 の Mailbox::ConversationFinder の strategy)を、この写しが実際に届いた宛先
    # (封筒の宛先)の店舗に絞る(D の裁定、2026-10-29)。上流の InReplyTo と ReceiverUuid は店舗を絞らずに会話を探すので、店舗 A と B を
    # 宛先に含むやり取りで、B が自分のアドレスからトイバコへ転送した写しも A の会話へ載り(会話の source_id で重複が止まり)、
    # B には何も残らない。
    # 封筒の宛先(SMTP の RCPT TO)は、SES が原本の先頭に足す Received の for で、宛先が 1 つに決まる時だけ使う(envelope_address)。
    # SES の取り込みが原本の前に載せる X-Original-To / Delivered-To は gem の destination(MIME の To・Cc の先頭)で、封筒の宛先では
    # ないので使わない。To・Cc などの header も使わない(1 回の受信の宛先に A の reply+<uuid> と B の公開アドレスがあると、
    # B に絞られて A の会話へ返信が載らなくなるため)。封筒の宛先が店舗の公開アドレス(channel の email か forward_to_email)の時は
    # その channel の account に絞り、受信箱では絞らない(同じ店舗の中で受信箱をまたぐ返信は今のまま)。封筒の宛先が決まらない時
    # (宛先が複数の 1 回の受信など)と、reply+<uuid> など channel でない時は上流のまま(super)。宛先が複数の 1 回の受信は、店舗ごとに
    # 分けない限りどちらか一方にしか載らないので、上流のままにする。上流の References は channel の受信箱で、NewConversation の
    # in_reply_to は channel の account で、もう絞っているので変えない。
    # 封筒の宛先が確かめられ、店舗の公開アドレスの時は、EmailChannelFinder もその channel を返す(EnvelopeChannelFinder)。overlay の
    # ChannelFinderRecipients は送信者が書ける To・Cc を X-Original-To などの header より先に見るので、To や Cc に別の店舗(A)の
    # 公開アドレスがあると、B に届いた写しの References と NewConversation が A を選び、A の会話か A の新しい会話へ載せていた。経路の判定
    # (ApplicationMailbox.toybaco_resolve_route)・References・NewConversation・再投入の宛先が、これで同じ channel に揃う。
    # 上流を上げる時は、InReplyToStrategy#find・ReceiverUuidStrategy#find の中身と、ここで呼ぶ private の helper
    # (sanitize_mailbox_value・extract_uuid_from_patterns・extract_uuid_from_receivers)の名前と、EmailChannelFinder の @email_object を
    # 確かめる。
    module ConversationScope
      module_function

      # 封筒の宛先の channel(店舗の公開アドレスの時)。決まらなければ nil。
      def envelope_channel(mail)
        address = envelope_address(mail)
        return unless address

        ::Channel::Email.find_by('lower(email) = :address OR lower(forward_to_email) = :address', address: address)
      end

      def envelope_account_id(mail)
        envelope_channel(mail)&.account_id
      end

      # 封筒の宛先が 1 つに決まる時だけ、その宛先を返す。SES は SMTP の宛先(RCPT TO)が 1 つの時だけ、原本の先頭に足す
      # Received(by inbound-smtp.<東京>)に for を付ける(再投入もこの for から header を作る)。先頭の Received は SES が付けるもので、
      # 送信者はその上に足せない。送信者が書ける下の Received は読まない(先頭だけを見る)。for が無ければ(宛先が複数)nil。
      # SES の取り込み(Toybaco::InboundEmail::RoutingHooks::SesSource)が原本の前に載せる X-Original-To / Delivered-To は gem の
      # destination(SES の通知の mail.destination の先頭)で、AWS の文書では MIME の To・Cc 由来の宛先(封筒の RCPT TO は
      # receipt.recipients)なので、封筒の宛先には使わない。
      def envelope_address(mail)
        return unless mail.respond_to?(:raw_source)

        received = Reingest.first_header(mail.raw_source.to_s, 'Received').to_s
        return unless received.match?(Reingest::SES_RECEIVED)

        address = InboundEmail.normalize_address(received[Reingest::RECEIVED_FOR, 1])
        address unless address.empty?
      end

      # EmailChannelFinder#perform への prepend。封筒の宛先が確かめられない時は今の順(To・Cc・X-Original-To などの header)のまま。
      module EnvelopeChannelFinder
        def perform
          ConversationScope.envelope_channel(@email_object) || super
        end
      end

      # 上流の InReplyToStrategy#find と同じ順(In-Reply-To の値ごとに、uuid の型の会話、その次に Message)で、会話と Message を
      # 封筒の宛先の店舗に絞って探す。
      module InReplyTo
        def find
          account_id = ConversationScope.envelope_account_id(mail)
          return super unless account_id
          return nil if mail.in_reply_to.blank?

          sanitize_mailbox_value(Array.wrap(mail.in_reply_to)).each do |in_reply_to|
            conversation = toybaco_scoped_conversation(in_reply_to, account_id)
            return conversation if conversation
          end
          nil
        end

        private

        def toybaco_scoped_conversation(in_reply_to, account_id)
          uuid = extract_uuid_from_patterns(in_reply_to)
          conversation = ::Conversation.find_by(uuid: uuid, account_id: account_id) if uuid
          conversation || ::Message.find_by(source_id: in_reply_to, account_id: account_id)&.conversation
        end
      end

      # reply+<uuid> の宛先は、その会話の店舗が出した宛先(上流の ConversationReplyMailer の Reply-To)。ただし上流は To の宛先
      # (MailPresenter#mail_receiver)で探すので、客が A の Reply-To(reply+<uuid>)と店舗 B のアドレスへ全員に返信し、B が自分の
      # アドレスからトイバコへ転送した写しも、To に残った A の reply+<uuid> で A の会話へ載る。InReplyTo と同じく、封筒の宛先が
      # 店舗の公開アドレスならその店舗に絞る。A の reply+<uuid> に直接届いた写しは、封筒の宛先が channel でないので上流のまま A に載る。
      # 上流の extract_uuid_from_receivers は最初に当たった uuid を 1 つだけ返すので、To が A・B の reply+<uuid> の順だと、A を店舗
      # 違いで退けた所で止まる。絞る時は、同じ宛先の並び(mail_receiver)と規則(local part が UUID_PATTERN)で uuid を順に全部見て、
      # 封筒の宛先の店舗の会話に当たった最初のものを返す。上流を上げる時は extract_uuid_from_receivers の並びと規則を確かめる。
      module ReceiverUuid
        def find
          account_id = ConversationScope.envelope_account_id(mail)
          return super unless account_id

          toybaco_receiver_uuids.each do |uuid|
            conversation = ::Conversation.find_by(uuid: uuid, account_id: account_id)
            return conversation if conversation
          end
          nil
        end

        private

        def toybaco_receiver_uuids
          ::MailPresenter.new(mail).mail_receiver.to_a.filter_map do |email|
            email.to_s.split('@').first.to_s.match(self.class::UUID_PATTERN)&.captures&.first
          end
        end
      end
    end
  end
end
