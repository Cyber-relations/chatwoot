# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # 受信メールの再投入(Toybaco::InboundEmail::Reingest)が重複を見る受信箱を、取り込みの処理(routing job)と同じ手順で決める。
    module DeliveryDestination
      module_function

      # routing job がこの原本を載せる受信箱(決められなければ nil)。処理とずれると、別の店舗の会話に続くメールで ingested を
      # 返しながら何も載らない(B 宛ての ActionMailbox の行だけが残る)ので、処理と同じ手順で決める。SupportMailbox(< ReplyMailbox)
      # と ReplyMailbox は上流の Mailbox::ConversationFinder の DEFAULT_STRATEGIES の順(ReceiverUuid → InReplyTo → References →
      # NewConversation)で会話を探す。ReceiverUuid と InReplyTo は overlay の ConversationScope で封筒の宛先(先頭の SES の Received
      # の for。宛先が 1 つに決まる時だけ)の店舗に絞られ(同じ店舗の中では受信箱をまたぐ。封筒の宛先が決まらないか channel で
      # ない時は上流のまま店舗を絞らない)、References は受信箱で絞られる。
      # strategy の class をそのまま呼ぶので、その絞り方も処理と同じに効く。会話を作る NewConversation を除いた strategy を同じ順で
      # 当て、さらに NewConversation の会話を作る前の探し方(existing_account_conversation)も当て、既存の会話があればその受信箱を
      # 宛先にする。無ければ NewConversation が会話を作る EmailChannelFinder(overlay の ChannelFinderRecipients と、封筒の宛先が
      # 確かめられた時の ConversationScope::EnvelopeChannelFinder を含む)の受信箱(channel が無ければ nil)。ReplyMailbox も同じ
      # ConversationFinder で NewConversation まで進むので、経路で分けない。
      # overlay の InboxRetentionBoundaries の NewMailConversation・ReplyMailbox は、載る受信箱の保持の確かめだけで、受信箱は変えない。
      def inbox(mail, route)
        return if route == :default

        conversation = existing_conversation(mail)
        return conversation.inbox if conversation

        ::EmailChannelFinder.new(mail).perform&.inbox
      end

      # 上流の strategy の find は、会話と Message を探すだけで何も書かない(書くのは除いた NewConversation の find だけ)。
      def existing_conversation(mail)
        new_conversation = ::Mailbox::ConversationFinderStrategies::NewConversationStrategy
        (::Mailbox::ConversationFinder::DEFAULT_STRATEGIES - [new_conversation]).each do |strategy|
          conversation = strategy.new(mail).find
          return conversation if conversation
        end
        existing_account_conversation(new_conversation.new(mail))
      end

      # 上流(v4.18.0)の NewConversationStrategy#find は、channel が無ければ nil、incoming_email_from_valid_email? でなければ nil、
      # find_conversation_by_in_reply_to(同じ店舗の会話の additional_attributes の in_reply_to。受信箱は絞らない)で見つかれば
      # その会話を返し、無ければ会話を作る。会話と contact を作る find は呼ばず、読みだけの private の find_conversation_by_in_reply_to
      # を send で呼ぶ(initialize も EmailChannelFinder と MailPresenter だけで何も書かない)。上流を上げる時は、この method の
      # 名前・読みだけであること・channel のある時だけ呼ばれることを確かめる。incoming_email_from_valid_email? で取り込みが
      # 落ちる時のずれ(再投入は ingested、処理は会話を作らない)は前からある別の話で、ここでは合わせない。
      def existing_account_conversation(strategy)
        strategy.send(:find_conversation_by_in_reply_to) if strategy.channel
      end
    end
  end
end
