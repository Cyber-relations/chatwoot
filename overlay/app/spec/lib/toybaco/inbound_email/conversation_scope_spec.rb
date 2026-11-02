# frozen_string_literal: true

require 'rails_helper'

# 受信メールの会話探しを、封筒の宛先の店舗に絞る(lib/toybaco/inbound_email/conversation_scope.rb)。客が店舗 A と B を宛先に含む
# やり取りに全員へ返信し、A と B がそれぞれ自分のアドレスからトイバコの公開アドレスへ転送した写しを、ApplicationMailbox の routing
# から mailbox の処理まで通す。原本は SES が受けた形で、封筒の宛先(SMTP の RCPT TO)は先頭の Received の for(SMTP の宛先が
# 1 つの時だけ付く)。SES の取り込みは、gem の destination(SES の通知の mail.destination の先頭。MIME の To・Cc 由来)を
# X-Original-To / Delivered-To で原本の前に載せる。
RSpec.describe Toybaco::InboundEmail::ConversationScope do
  include ActionMailbox::TestHelper

  let(:domain) { 'inbox.staging.toybaco.jp' }
  let(:account_a) { create(:account) }
  let(:account_b) { create(:account) }
  let(:address_a) { "shop-#{account_a.id}@#{domain}" }
  let(:address_b) { "shop-#{account_b.id}@#{domain}" }
  let!(:channel_a) { create(:channel_email, account: account_a, email: address_a, forward_to_email: address_a) }
  let!(:channel_b) { create(:channel_email, account: account_b, email: address_b, forward_to_email: address_b) }
  let(:conversation_a) { create(:conversation, account: account_a, inbox: channel_a.inbox) }
  let(:reply_id) { "reply-all-#{SecureRandom.hex(6)}@mail.example.invalid" }

  # SES が受けた客の全員への返信の原本。
  def original(to:, cc: nil, in_reply_to: nil, references: nil, received_for: nil)
    received = 'Received: from mail.example.invalid (mail.example.invalid [192.0.2.1])' \
               "\r\n by inbound-smtp.ap-northeast-1.amazonaws.com with SMTP id #{SecureRandom.hex(10)}"
    received += "\r\n for #{received_for}" if received_for
    ['Return-Path: <customer@example.invalid>', "#{received};\r\n Thu, 29 Oct 2026 10:00:00 +0000 (UTC)",
     'From: Customer <customer@example.invalid>', "To: #{to}", cc && "Cc: #{cc}", 'Subject: Re: inquiry', "Message-ID: <#{reply_id}>",
     in_reply_to && "In-Reply-To: <#{in_reply_to}>", references && "References: <#{references}>", 'MIME-Version: 1.0',
     'Content-Type: text/plain; charset=UTF-8', '',
     '全員への返信です。'].compact.join("\r\n")
  end

  # SES の取り込みと同じく、原本の前に gem の destination を X-Original-To / Delivered-To で載せ(nil なら載せない)、routing から
  # 処理まで通す。
  def deliver(raw, destination: nil)
    receive_inbound_email_from_source(Toybaco::InboundEmail.ses_action_mailbox_source(content: raw, destination: destination.to_s))
  end

  # 1 つの宛先(address)として SES に届いた写し(先頭の Received の for が address)。原本の前の header も address にする。
  def deliver_to(address, **headers)
    deliver(original(received_for: address, **headers), destination: address)
  end

  # SES の受信の SNS の通知(receipt の action が SNS で、原本は content)。AWS の文書では、mail.destination は MIME の To・Cc 由来の
  # 宛先で、封筒の RCPT TO は receipt.recipients。
  def sns_notification(content:, destination:, recipients:)
    topic = 'arn:aws:sns:ap-northeast-1:000000000000:toybaco-gate-inbound'
    message = { notificationType: 'Received', mail: { source: 'customer@example.invalid', destination: destination },
                receipt: { recipients: recipients, action: { type: 'SNS', topicArn: topic, encoding: 'UTF8' } }, content: content }
    Aws::ActionMailbox::SES::SNSNotification.new({ Type: 'Notification', TopicArn: topic, Message: message.to_json }.to_json)
  end

  # A が出した返信の Message-ID。uuid の型は上流の ConversationReplyMailer の形(conversation/<uuid>/messages/<id>@)で、上流の
  # InReplyTo はその uuid で会話を探す。ただの型は、A の会話の Message の source_id で探す。
  def a_message_id(form)
    return "conversation/#{conversation_a.uuid}/messages/1@#{domain}" if form == :uuid

    "a-reply-#{SecureRandom.hex(6)}@shop-a.example.invalid".tap do |id|
      create(:message, account: account_a, inbox: channel_a.inbox, conversation: conversation_a, message_type: :outgoing, source_id: id)
    end
  end

  # その受信箱に載った客の返信の、会話の id。
  def landed(inbox)
    Message.where(inbox_id: inbox.id, source_id: reply_id).pluck(:conversation_id)
  end

  %i[uuid plain].each do |form|
    it "店舗をまたぐ全員への返信(In-Reply-To が A の返信の #{form} の Message-ID)は、A の写しは A の会話に、B の転送の写しは B の新しい会話に載る" do
      parent = a_message_id(form)
      deliver_to(address_a, to: 'info@shop-a.example.invalid', cc: 'info@shop-b.example.invalid', in_reply_to: parent)
      deliver_to(address_b, to: 'info@shop-a.example.invalid', cc: 'info@shop-b.example.invalid', in_reply_to: parent)

      expect(landed(channel_a.inbox)).to eq([conversation_a.id])
      expect(landed(channel_b.inbox).size).to eq(1)
      expect(Conversation.where(account_id: account_a.id).count).to eq(1)
    end
  end

  it '店舗 B へ転送された写しの To に A の会話の reply+<uuid> が残っていても、封筒の宛先が B なら B の新しい会話に載り、A の会話は増えない' do
    reply_address = "reply+#{conversation_a.uuid}@#{domain}"
    deliver_to(reply_address, to: reply_address, cc: 'info@shop-b.example.invalid')
    # 転送元が付けた元の Delivered-To は原本の中に残るが、封筒の宛先は先頭の SES の Received の for で決まる。
    forwarded = original(received_for: address_b, to: reply_address, cc: 'info@shop-b.example.invalid')
    deliver(forwarded.sub("\r\nFrom: ", "\r\nDelivered-To: info@shop-b.example.invalid\r\nFrom: "), destination: address_b)

    expect(landed(channel_a.inbox)).to eq([conversation_a.id])
    expect(landed(channel_b.inbox).size).to eq(1)
    expect(Conversation.where(account_id: account_a.id).count).to eq(1)
  end

  # 上流の extract_uuid_from_receivers は最初の uuid だけを返す。絞る時は To の reply+<uuid> を順に全部見る。
  it '封筒の宛先が B で To が A・B の reply+<uuid> の順の写しは、B の既存の会話に載り、B に新しい会話はできない。再投入の宛先も同じ会話' do
    conversation_b = create(:conversation, account: account_b, inbox: channel_b.inbox)
    raw = original(received_for: address_b, to: "reply+#{conversation_a.uuid}@#{domain}, reply+#{conversation_b.uuid}@#{domain}")
    source = Toybaco::InboundEmail.ses_action_mailbox_source(content: raw, destination: address_b)

    expect(Toybaco::InboundEmail::DeliveryDestination.existing_conversation(Mail.from_source(source))).to eq(conversation_b)
    deliver(raw, destination: address_b)
    expect(landed(channel_b.inbox)).to eq([conversation_b.id])
    expect(Conversation.where(account_id: account_b.id).count).to eq(1)
  end

  it '宛先が複数の 1 回の受信(To が A の reply+<uuid>、Cc が B の公開アドレス、封筒の宛先なし)は、今までどおり A の会話に載る' do
    reply_address = "reply+#{conversation_a.uuid}@#{domain}"
    deliver(original(to: reply_address, cc: address_b))

    expect(landed(channel_a.inbox)).to eq([conversation_a.id])
    expect(Conversation.where(account_id: account_b.id).count).to eq(0)
  end

  # SES の取り込みは、宛先が複数でも通知の mail.destination の先頭を 1 つだけ X-Original-To / Delivered-To に載せる。
  it '宛先が複数の 1 回の受信は、原本の前の X-Original-To / Delivered-To に B の公開アドレスが載っていても(Received に for が無い)、上流のまま A の会話に載る' do
    reply_address = "reply+#{conversation_a.uuid}@#{domain}"
    deliver(original(to: reply_address, cc: address_b), destination: address_b)

    expect(landed(channel_a.inbox)).to eq([conversation_a.id])
    expect(Conversation.where(account_id: account_b.id).count).to eq(0)
  end

  # 封筒の宛先は先頭の SES の Received の for で、原本の前の X-Original-To / Delivered-To(gem の destination。MIME の To・Cc の
  # 先頭)の値には関わらない(envelope_address)。
  it '先頭の Received の for が B で、原本の前の X-Original-To と Delivered-To が A の写しは、B にだけ載り、A の会話は増えない' do
    reply_address = "reply+#{conversation_a.uuid}@#{domain}"
    deliver(original(to: reply_address, received_for: address_b), destination: address_a)

    expect(landed(channel_b.inbox).size).to eq(1)
    expect([landed(channel_a.inbox), Conversation.where(account_id: account_a.id).count]).to eq([[], 1])
  end

  it '先頭の Received の for と X-Original-To が B で、Delivered-To だけが A の写しも、B にだけ載り、A の会話は増えない' do
    reply_address = "reply+#{conversation_a.uuid}@#{domain}"
    raw = original(to: reply_address, received_for: address_b)
    receive_inbound_email_from_source("X-Original-To: #{address_b}\r\nDelivered-To: #{address_a}\r\n#{raw}")

    expect(landed(channel_b.inbox).size).to eq(1)
    expect([landed(channel_a.inbox), Conversation.where(account_id: account_a.id).count]).to eq([[], 1])
  end

  # 実際の SES の通知の形: mail.destination は MIME の To・Cc 由来(A)で、封筒の RCPT TO(receipt.recipients と先頭の Received の
  # for)は B。gem の SNSNotification#message_content(overlay の RoutingHooks::SesSource)は原本の前に A を載せる。
  it 'SES の通知の mail.destination が A、receipt.recipients と先頭の Received の for が B の写しは、SNSNotification から B にだけ載る' do
    parent = a_message_id(:plain)
    raw = original(to: address_a, in_reply_to: parent, received_for: address_b)
    source = sns_notification(content: raw, destination: [address_a], recipients: [address_b]).message_content

    expect(source).to start_with("X-Original-To: #{address_a}\r\nDelivered-To: #{address_a}\r\n")
    receive_inbound_email_from_source(source)
    expect(landed(channel_b.inbox).size).to eq(1)
    expect([landed(channel_a.inbox), conversation_a.messages.count]).to eq([[], 1])
  end

  # 先頭の Received が SES のもの(by inbound-smtp.<東京>)でなければ、for があっても封筒の宛先にしない。
  it '先頭の Received が SES のものでない写しは、for が B でも上流のまま To の reply+<uuid> の A の会話に載り、B に会話はできない' do
    reply_address = "reply+#{conversation_a.uuid}@#{domain}"
    raw = original(to: reply_address, received_for: address_b)
    deliver(raw.sub(' by inbound-smtp.ap-northeast-1.amazonaws.com ', ' by mx.example.invalid '))

    expect(landed(channel_a.inbox)).to eq([conversation_a.id])
    expect(Conversation.where(account_id: account_b.id).count).to eq(0)
  end

  # 送信者は SES の Received の下に Received を書ける。先頭の SES の Received に for が無ければ(宛先が複数)、下の Received は読まない。
  it '先頭の SES の Received に for が無い写しは、下に SES の形で for が B の Received があっても、上流のまま A の会話に載り、B に会話はできない' do
    reply_address = "reply+#{conversation_a.uuid}@#{domain}"
    forged = "Received: from forged.example.invalid by inbound-smtp.ap-northeast-1.amazonaws.com with SMTP id #{SecureRandom.hex(10)}" \
             "\r\n for #{address_b};\r\n Thu, 29 Oct 2026 09:59:00 +0000 (UTC)"
    raw = original(to: reply_address, cc: address_b)
    deliver(raw.sub("\r\nFrom: ", "\r\n#{forged}\r\nFrom: "), destination: reply_address)

    expect(landed(channel_a.inbox)).to eq([conversation_a.id])
    expect(Conversation.where(account_id: account_b.id).count).to eq(0)
  end

  # To・Cc に別の店舗(A)の登録済みの公開アドレスがあっても、封筒の宛先が B と確かめられた写しは、経路・References・NewConversation
  # とも B の channel で揃う(EnvelopeChannelFinder)。
  it 'To に A の公開アドレスがあり References が A の会話の Message を指していても、封筒の宛先が B の写しは B に 1 通だけ載り、A の会話は変わらない' do
    deliver_to(address_b, to: address_a, references: a_message_id(:plain))

    expect(landed(channel_b.inbox).size).to eq(1)
    expect([landed(channel_a.inbox), conversation_a.messages.count]).to eq([[], 1])
  end

  it 'To に A の公開アドレスがあり References も無い、封筒の宛先が B の写しは、B の新しい会話に 1 通だけ載る' do
    deliver_to(address_b, to: address_a)

    expect(landed(channel_b.inbox).size).to eq(1)
    expect(Conversation.where(account_id: account_a.id).count).to eq(0)
  end

  it 'Cc に A の公開アドレスがある、封筒の宛先が B の写しも、B に 1 通だけ載る' do
    deliver_to(address_b, to: 'info@shop-b.example.invalid', cc: address_a)

    expect(landed(channel_b.inbox).size).to eq(1)
    expect(Conversation.where(account_id: account_a.id).count).to eq(0)
  end

  it '宛先が複数の 1 回の受信(封筒が確かめられない)で To に A の公開アドレスがある時は、今までどおり A に載る' do
    deliver(original(to: address_a, cc: address_b), destination: address_b)

    expect(Conversation.where(account_id: account_a.id).count).to eq(1)
    expect([landed(channel_a.inbox).size, landed(channel_b.inbox)]).to eq([1, []])
  end

  it '同じ店舗の中で受信箱をまたぐ返信(I2 に届き、In-Reply-To が I1 の会話の Message)は、今までどおり I1 の会話に載る' do
    second_address = "shop-#{account_a.id}-second@#{domain}"
    second = create(:channel_email, account: account_a, email: second_address, forward_to_email: second_address)
    deliver_to(second_address, to: 'info@shop-a.example.invalid', in_reply_to: a_message_id(:plain))

    expect(landed(channel_a.inbox)).to eq([conversation_a.id])
    expect(Conversation.where(inbox_id: second.inbox.id).count).to eq(0)
  end

  it '封筒の宛先が店舗の公開アドレスでない reply+<uuid> だけの受信は、上流のまま reply+<uuid> の会話に載る' do
    reply_address = "reply+#{conversation_a.uuid}@#{domain}"
    deliver_to(reply_address, to: reply_address, cc: 'info@shop-b.example.invalid')

    expect(landed(channel_a.inbox)).to eq([conversation_a.id])
  end

  it '封筒の宛先が店舗の公開アドレスでない受信の In-Reply-To は、上流のまま店舗を絞らずに会話を探す' do
    unknown = "reply+#{SecureRandom.uuid}@#{domain}"
    deliver_to(unknown, to: unknown, in_reply_to: a_message_id(:plain))

    expect(landed(channel_a.inbox)).to eq([conversation_a.id])
  end
end
