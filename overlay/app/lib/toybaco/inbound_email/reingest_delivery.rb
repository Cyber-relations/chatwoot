# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # 受信メールの再投入(Toybaco::InboundEmail::Reingest)の、宛先の受信箱での重複の判定と取り込み。結果の語(ingested / duplicate /
    # stranded)を返す。
    module ReingestDelivery
      # pending・processing の行を処理中とみなす時間。routing の job は受けてすぐ積まれ、1 通の処理は数秒から数分で終わる
      # (processing! で updated_at が進み、終われば delivered・bounced・failed になる)。これより古いまま残った行は処理中とみなさない。
      IN_FLIGHT_SECONDS = 3600

      module_function

      # 重複の判定は宛先の受信箱に限る。上流(Chatwoot v4.18.0)も受信箱ごとに見ている: IMAP は
      # Imap::BaseFetchEmailService#email_already_present? の channel.inbox.messages.exists?(source_id:)(messages.inbox_id と
      # messages.source_id)、ReplyMailbox は会話の messages.source_id(MailboxHelper#create_message)。ActionMailbox の行の一意は
      # message_id と message_checksum(原本の SHA1。先頭に載せた宛先を含む)の組で、Message-ID だけでは判定しない。次の順に見る。
      # 1. 宛先の受信箱に、その Message-ID の Message(messages.inbox_id と messages.source_id)があれば duplicate。
      # 2. 同じ message_id の行のうち、原本が同じ規則(DeliveryDestination)で宛先の受信箱へ解決される行に、IN_FLIGHT_SECONDS より
      #    新しい pending・processing があれば、処理中なので duplicate。
      # 3. 宛先の受信箱へ解決される行があるのに 1・2 に当たらない(処理済みの delivered・bounced・failed か、古い pending・processing
      #    しか無い)時は、行の status と宛先の Message を読み直したうえで(settled)stranded(run は失敗)。会話探しを封筒の宛先の店舗に絞る前に別の店舗の会話へ読まれた写しなど、宛先に
      #    Message が無いまま行だけが残っている。新しい行は作らない(同じ bytes は一意の制約で作れない)。自動で routing し直すことも
      #    しない: 同時の再投入や待たされた元の job と競合すると 2 回処理され、In-Reply-To の無いメールでは会話が二重にできる。
      #    failed の行は Sidekiq の retry が処理し直しうる。戻すのは運営の手作業(docs/inbound-email.md の stranded)。
      # 4. 行が無ければ新しい行を作る。
      # 宛先の受信箱を決められない返信(既存の会話も宛先の channel も無い reply+<uuid>)だけは、今までどおり全店舗の Message-ID で見る。
      def ingest(source, message_id, inbox)
        return 'duplicate' if landed?(message_id, inbox)

        rows = destination_rows(message_id, inbox)
        return 'duplicate' if in_flight?(rows)
        return settled(message_id, inbox, rows) unless rows.empty?

        ::ActionMailbox::InboundEmail.create_and_extract_message_id!(source) ? 'ingested' : 'duplicate'
      end

      def landed?(message_id, inbox)
        return ::ActionMailbox::InboundEmail.exists?(message_id: message_id) || ::Message.exists?(source_id: message_id) unless inbox

        ::Message.exists?(inbox_id: inbox.id, source_id: message_id)
      end

      def in_flight?(rows)
        since = Time.current - IN_FLIGHT_SECONDS
        rows.any? { |row| (row.pending? || row.processing?) && row.updated_at > since }
      end

      # stranded を返す前に、読み取りの間に routing が終わっていないかを確かめ直す。landed? の後、行を読むまでの間に routing の
      # worker が宛先の Message を作って行を delivered にすると、読んだ行だけでは正しく届いたものを stranded と誤る。worker は
      # processing! → Message の作成 → delivered! の順に進むので、行の status を先に読み直し(1 時間以内の pending・processing なら
      # 処理中)、その後に宛先の Message を読み直す。どちらも query の cache を通さない。
      def settled(message_id, inbox, rows)
        ::ActiveRecord::Base.uncached do
          fresh = ::ActionMailbox::InboundEmail.where(id: rows.map(&:id)).to_a
          in_flight?(fresh) || landed?(message_id, inbox) ? 'duplicate' : 'stranded'
        end
      end

      # 同じ message_id の ActionMailbox の行のうち、原本が宛先の受信箱へ解決されるもの。
      def destination_rows(message_id, inbox)
        ::ActionMailbox::InboundEmail.where(message_id: message_id).select do |row|
          row_mail = ::Mail.from_source(row.source)
          DeliveryDestination.inbox(row_mail, ::ApplicationMailbox.toybaco_resolve_route(row_mail)) == inbox
        end
      end
    end
  end
end
