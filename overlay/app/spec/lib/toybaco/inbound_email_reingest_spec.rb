# frozen_string_literal: true

require 'rails_helper'

Rails.application.load_tasks unless Rake::Task.task_defined?('toybaco:inbound_email_reingest')

# 受信メールの再投入(rake toybaco:inbound_email_reingest、Toybaco::InboundEmail::Reingest)。S3 は aws-sdk の stub_responses で偽装し、
# 取り込み・経路・会話は実の ActionMailbox と ApplicationMailbox(SupportMailbox)で確かめる。受信 ENV は gate の test 環境と同じ値を
# 明示する(inbox.staging.toybaco.jp、ses、東京の SNS)。原本は SES が S3 へ置く形(先頭に SES の Received と for)。
RSpec.describe 'toybaco:inbound_email_reingest', type: :task do
  let(:reingest) { Toybaco::InboundEmail::Reingest }
  let(:message_id) { 'o3vrnil0e2ic28trm7dfhrc2v0clambda4nbp0g1' }
  let(:bucket) { 'toybaco-staging-inbound-email' }
  let(:environment) do
    { 'MAILER_INBOUND_EMAIL_DOMAIN' => 'inbox.staging.toybaco.jp', 'RAILS_INBOUND_EMAIL_SERVICE' => 'ses',
      'ACTION_MAILBOX_SES_SNS_TOPIC' => 'arn:aws:sns:ap-northeast-1:000000000000:toybaco-gate-inbound',
      'TOYBACO_INBOUND_EMAIL_BUCKET' => bucket }
  end
  let(:account) { create(:account) }
  let(:address) { "shop-#{account.id}@inbox.staging.toybaco.jp" }
  let!(:channel) { create(:channel_email, account: account, email: address, forward_to_email: address) }
  let(:mail_id) { "reingest-#{SecureRandom.hex(6)}@mail.example.invalid" }
  let(:requests) { [] }

  def raw_email(to: address, received_for: address, message_header: "Message-ID: <#{mail_id}>", extra_received: nil, in_reply_to: nil)
    received = 'Received: from mail.example.invalid (mail.example.invalid [192.0.2.1])' \
               "\r\n by inbound-smtp.ap-northeast-1.amazonaws.com with SMTP id #{message_id}"
    received += "\r\n for #{received_for}" if received_for
    [
      'Return-Path: <customer@example.invalid>', "#{received};\r\n Tue, 20 Oct 2026 10:00:00 +0000 (UTC)",
      'X-SES-Spam-Verdict: PASS', 'X-SES-Virus-Verdict: PASS', extra_received,
      'From: Customer <customer@example.invalid>', "To: #{to}", 'Subject: reingest fixture subject',
      message_header, in_reply_to && "In-Reply-To: <#{in_reply_to}>", 'MIME-Version: 1.0', 'Content-Type: text/plain; charset=UTF-8', '',
      '再投入の本文です。'
    ].compact.join("\r\n")
  end

  def s3_client(objects = {})
    Aws::S3::Client.new(stub_responses: true, region: 'ap-northeast-1').tap do |client|
      client.stub_responses(:get_object, lambda do |context|
        requests << context.params.slice(:bucket, :key)
        body = objects[context.params[:key]]
        body ? { body: body, content_length: body.bytesize } : 'NoSuchKey'
      end)
    end
  end

  def run(id = message_id, raw: raw_email, env: environment)
    reingest.run(id, environment: env, client: s3_client("inbound/#{message_id}" => raw))
  end

  def inbound_emails = ActionMailbox::InboundEmail.where(message_id: mail_id)
  def conversations = Conversation.where(inbox_id: channel.inbox.id)

  it '原本を SES の宛先付きで取り込み、通常の routing job で SupportMailbox の会話になる。2 回目は重複で何も書かない' do
    expect([run, requests]).to eq(['ingested', [{ bucket: bucket, key: "inbound/#{message_id}" }]])
    expect(inbound_emails.sole.source).to start_with("X-Original-To: #{address}\r\nDelivered-To: #{address}\r\n")
    expect(ActionMailbox::RoutingJob).to have_been_enqueued.exactly(:once)
    perform_enqueued_jobs(only: ActionMailbox::RoutingJob)
    expect([inbound_emails.sole.status, conversations.count, conversations.sole.messages.where(source_id: mail_id).count]).to eq(['delivered', 1, 1])

    expect(run).to eq('duplicate')
    expect([inbound_emails.count, conversations.count, Message.where(source_id: mail_id).count]).to eq([1, 1, 1])
  end

  it '店舗のメールからの転送(To が受信アドレスでない)も、先頭の SES の Received の for で同じ受信箱へ載る' do
    expect(run(raw: raw_email(to: 'store-owner@shop.example.invalid'))).to eq('ingested')
    expect(inbound_emails.sole.source).to start_with("X-Original-To: #{address}\r\n")
    perform_enqueued_jobs(only: ActionMailbox::RoutingJob)
    expect(conversations.count).to eq(1)
  end

  it 'SES の Received の for が無い時、下の Received(送信者が書ける)の for は宛先にしない' do
    other = create(:channel_email, account: create(:account), email: 'shop-990001@inbox.staging.toybaco.jp',
                                   forward_to_email: 'shop-990001@inbox.staging.toybaco.jp')
    forged = 'Received: from attacker.invalid by inbound-smtp.ap-northeast-1.amazonaws.com with SMTP id x for ' \
             'shop-990001@inbox.staging.toybaco.jp; Tue, 20 Oct 2026 09:59:00 +0000'
    raw = raw_email(to: 'store-owner@shop.example.invalid', received_for: nil, extra_received: forged)
    expect(run(raw: raw)).to eq('rejected')
    expect([inbound_emails.count, Conversation.where(inbox_id: other.inbox.id).count]).to eq([0, 0])
  end

  it 'その Message-ID の Message が既にあれば(ActionMailbox の行が消えた後も)重複として取り込まない' do
    conversation = create(:conversation, account: account, inbox: channel.inbox)
    create(:message, account: account, inbox: channel.inbox, conversation: conversation, source_id: mail_id)
    expect(run).to eq('duplicate')
    expect(inbound_emails.count).to eq(0)
  end

  it '同じ受信箱へ載る ActionMailbox の行が既にあれば、原本の bytes が違っても routing の前でも重複で、行を足さない' do
    ActionMailbox::InboundEmail.create_and_extract_message_id!(
      Toybaco::InboundEmail.ses_action_mailbox_source(content: "X-SES-Receipt: fixture\r\n#{raw_email}", destination: address)
    )
    clear_enqueued_jobs

    expect(run).to eq('duplicate')
    expect([inbound_emails.count, Message.where(source_id: mail_id).count]).to eq([1, 0])
    expect(ActionMailbox::RoutingJob).not_to have_been_enqueued
  end

  # 上流の NewConversationStrategy は会話を作る前に、同じ店舗の会話を In-Reply-To(会話の additional_attributes の in_reply_to)で探す。
  it '同じ店舗の別の受信箱の会話に続く写し(In-Reply-To)は、処理と同じくその会話の受信箱で判定し、あれば重複で何も書かない' do
    second_address = "shop-#{account.id}-second@inbox.staging.toybaco.jp"
    second = create(:channel_email, account: account, email: second_address, forward_to_email: second_address)
    copy = raw_email(to: 'store-owner@shop.example.invalid', received_for: second_address,
                     in_reply_to: "outbound-#{SecureRandom.hex(6)}@shop.example.invalid")
    # 上流は会話を作る時の mail['In-Reply-To'].value をそのまま additional_attributes に残し、同じ値で探す。
    conversation = create(:conversation, account: account, inbox: channel.inbox,
                                         additional_attributes: { 'in_reply_to' => Mail.from_source(copy)['In-Reply-To'].value })
    create(:message, account: account, inbox: channel.inbox, conversation: conversation, source_id: mail_id)

    expect([run(raw: copy), run(raw: copy)]).to eq(%w[duplicate duplicate])
    expect([ActionMailbox::InboundEmail.count, Message.where(source_id: mail_id).pluck(:inbox_id).tally]).to eq([0, { channel.inbox.id => 1 }])
    expect(Conversation.where(inbox_id: second.inbox.id).count).to eq(0)
  end

  # 重複は宛先の受信箱に限って見る(同じメールが転送などで店舗 A と B の両方へ届き、A だけが着地して B が DLQ に入った時に B を戻せる)。
  context 'when the same Message-ID already landed in another store' do
    let(:other_account) { create(:account) }
    let(:other_address) { "shop-#{other_account.id}@inbox.staging.toybaco.jp" }
    let!(:other_channel) { create(:channel_email, account: other_account, email: other_address, forward_to_email: other_address) }

    def forwarded(destination)
      raw_email(to: 'store-owner@shop.example.invalid', received_for: destination)
    end

    def landed
      [channel.inbox, other_channel.inbox].map { |inbox| Message.where(inbox_id: inbox.id, source_id: mail_id).count }
    end

    it '店舗 A に着地済みでも、店舗 B 宛ての再投入は重複で止まらず B の会話になる。同じ受信箱への二度目は今までどおり重複' do
      expect(run(raw: forwarded(address))).to eq('ingested')
      perform_enqueued_jobs(only: ActionMailbox::RoutingJob)
      expect(landed).to eq([1, 0])

      expect(run(raw: forwarded(other_address))).to eq('ingested')
      perform_enqueued_jobs(only: ActionMailbox::RoutingJob)
      expect(landed).to eq([1, 1])
      expect(Conversation.where(inbox_id: other_channel.inbox.id).count).to eq(1)

      expect([run(raw: forwarded(address)), run(raw: forwarded(other_address))]).to eq(%w[duplicate duplicate])
      expect([inbound_emails.count, landed]).to eq([2, [1, 1]])
    end

    # routing job の In-Reply-To は封筒の宛先(再投入は SES の Received の for から載せる)の店舗の中で会話を探す
    # (Toybaco::InboundEmail::ConversationScope)ので、別の店舗(A)の会話に続く写しも、B に届いた分は B の会話になる。
    # 再投入も同じ規則で B の受信箱で判定する。
    it '店舗 B へ転送された写しが店舗 A の会話に続く(In-Reply-To)時も、B の受信箱で判定して取り込み、B の会話になる。A の会話は増えず、二度目は重複' do
      parent_id = "reingest-parent-#{SecureRandom.hex(6)}@mail.example.invalid"
      conversation = create(:conversation, account: account, inbox: channel.inbox)
      [parent_id, mail_id].each { |id| create(:message, account: account, inbox: channel.inbox, conversation: conversation, source_id: id) }
      copy = raw_email(to: 'store-owner@shop.example.invalid', received_for: other_address, in_reply_to: parent_id)

      expect(run(raw: copy)).to eq('ingested')
      perform_enqueued_jobs(only: ActionMailbox::RoutingJob)
      expect(run(raw: copy)).to eq('duplicate')
      expect([inbound_emails.count, landed, conversation.messages.count]).to eq([1, [1, 1], 2])
      expect(Conversation.where(inbox_id: other_channel.inbox.id).count).to eq(1)
    end

    # 経路が ReplyMailbox(To の reply+<uuid>)でも、処理は同じ ConversationFinder で NewConversation まで進むので、B の受信箱で判定する。
    it '店舗 B へ転送された写しの To に A の会話の reply+<uuid> が残っていても、B の受信箱で判定して取り込み、B の会話になる。二度目は重複' do
      conversation = create(:conversation, account: account, inbox: channel.inbox)
      create(:message, account: account, inbox: channel.inbox, conversation: conversation, source_id: mail_id)
      copy = raw_email(to: "reply+#{conversation.uuid}@inbox.staging.toybaco.jp", received_for: other_address)

      expect(run(raw: copy)).to eq('ingested')
      perform_enqueued_jobs(only: ActionMailbox::RoutingJob)
      expect(run(raw: copy)).to eq('duplicate')
      expect([inbound_emails.count, landed, conversation.messages.count]).to eq([1, [1, 1], 1])
    end

    # To・Cc の公開アドレスより封筒の宛先(SES の Received の for)の channel を先に見るので、経路・会話探し・宛先が B で揃う。
    it '封筒の宛先が B の写しの To に A の公開アドレスがあっても、B の受信箱で判定して取り込み、B の会話になる。二度目は重複' do
      expect(run).to eq('ingested')
      perform_enqueued_jobs(only: ActionMailbox::RoutingJob)
      copy = raw_email(to: address, received_for: other_address)

      expect(run(raw: copy)).to eq('ingested')
      perform_enqueued_jobs(only: ActionMailbox::RoutingJob)
      expect(run(raw: copy)).to eq('duplicate')
      expect([inbound_emails.count, landed]).to eq([2, [1, 1]])
    end

    # 会話探しを封筒の宛先の店舗に絞る前に、A の会話へ読まれて処理済みになった B の写しの行(A の会話は source_id の重複で何も
    # 作らず、B には何も載らない)を作る。同じ bytes は一意の制約で新しい行にできない。
    def stale_b_copy(status)
      parent_id = "reingest-parent-#{SecureRandom.hex(6)}@mail.example.invalid"
      conversation = create(:conversation, account: account, inbox: channel.inbox)
      [parent_id, mail_id].each { |id| create(:message, account: account, inbox: channel.inbox, conversation: conversation, source_id: id) }
      copy = raw_email(to: 'store-owner@shop.example.invalid', received_for: other_address, in_reply_to: parent_id)
      source = Toybaco::InboundEmail.ses_action_mailbox_source(content: copy, destination: other_address)
      ActionMailbox::InboundEmail.create_and_extract_message_id!(source).public_send(:"#{status}!")
      clear_enqueued_jobs
      [copy, conversation]
    end

    # 行も job も増えず、行の status も変わらず、B に Message は無いまま。
    def untouched(status)
      expect(ActionMailbox::RoutingJob).not_to have_been_enqueued
      expect([inbound_emails.count, inbound_emails.sole.status, landed]).to eq([1, status.to_s, [1, 0]])
    end

    # 宛先(B)へ解決される行が処理済みか古いまま残り、B に Message が無いのは stranded(run は失敗)。自動では routing し直さない
    # (同時の再投入や待たされた元の job と競合すると 2 回処理され、会話が二重にできうる)。戻すのは運営の手作業。
    it '処理済み(delivered)の B の写しの行が残り B に Message が無い時は、何度流しても stranded で、行も job も増えず status も変わらない' do
      copy, conversation = stale_b_copy(:delivered)

      expect([run(raw: copy), run(raw: copy)]).to eq(%w[stranded stranded])
      untouched(:delivered)
      expect(conversation.messages.count).to eq(2)
    end

    it 'まだ処理されていない(pending の)B の写しの行がある時は、今までどおり重複で、routing し直さない' do
      copy, = stale_b_copy(:pending)

      expect(run(raw: copy)).to eq('duplicate')
      expect(ActionMailbox::RoutingJob).not_to have_been_enqueued
      expect([inbound_emails.count, landed]).to eq([1, [1, 0]])
    end

    # failed の行は Sidekiq の retry が処理し直しうるので、routing し直すと二重になりうる。
    it 'failed の B の写しの行だけがある時も stranded で、routing し直さない' do
      copy, = stale_b_copy(:failed)

      expect(run(raw: copy)).to eq('stranded')
      untouched(:failed)
    end

    it 'まだ処理中(1 時間以内に更新された processing)の B の写しの行がある時も、重複で、routing し直さない' do
      copy, = stale_b_copy(:processing)

      expect(run(raw: copy)).to eq('duplicate')
      expect(ActionMailbox::RoutingJob).not_to have_been_enqueued
    end

    # 宛先の Message の確かめと行の読み取りの間に routing が進んでも、stranded と誤らない(stranded の前に読み直す)。
    it '確かめと行の読み取りの間に routing が終わった(B に Message ができ行が delivered になった)時は、stranded ではなく重複' do
      copy, = stale_b_copy(:pending)
      allow(Toybaco::InboundEmail::ReingestDelivery).to receive(:destination_rows).and_wrap_original do |original, *args|
        inbound_emails.sole.route
        original.call(*args)
      end

      expect(run(raw: copy)).to eq('duplicate')
      expect([inbound_emails.sole.status, landed]).to eq(['delivered', [1, 1]])
    end

    it '行を読んだ後に行が pending に戻った(新しい updated_at)時は、stranded ではなく重複' do
      copy, = stale_b_copy(:delivered)
      allow(Toybaco::InboundEmail::ReingestDelivery).to receive(:destination_rows).and_wrap_original do |original, *args|
        original.call(*args).tap { inbound_emails.sole.pending! }
      end

      expect(run(raw: copy)).to eq('duplicate')
      expect([inbound_emails.sole.status, landed]).to eq(['pending', [1, 0]])
    end

    # 1 時間(ReingestDelivery::IN_FLIGHT_SECONDS)より古いまま残った pending・processing の行は処理中とみなさない。
    %i[pending processing].each do |status|
      it "1 時間より古いまま残った #{status} の B の写しの行だけがある時は stranded で、routing し直さない" do
        copy, = stale_b_copy(status)

        travel(2.hours) { expect(run(raw: copy)).to eq('stranded') }
        untouched(status)
      end
    end

    it '別の店舗の受信箱にだけその Message-ID の Message がある時(ActionMailbox の行が消えた後)も、この受信箱へは取り込む' do
      conversation = create(:conversation, account: other_account, inbox: other_channel.inbox)
      create(:message, account: other_account, inbox: other_channel.inbox, conversation: conversation, source_id: mail_id)

      expect(run).to eq('ingested')
      perform_enqueued_jobs(only: ActionMailbox::RoutingJob)
      expect([inbound_emails.count, landed]).to eq([1, [1, 1]])
    end
  end

  it '原本が無ければ not_found で、ActionMailbox に何も書かない' do
    result = reingest.run(message_id, environment: environment, client: s3_client)
    expect([result, requests.size, ActionMailbox::InboundEmail.count]).to eq(['not_found', 1, 0])
  end

  it 'SES の messageId の形でない値は S3 を読まずに rejected' do
    ['', '../inbound/x', "inbound/#{message_id}", 'AMAZON_SES_SETUP_NOTIFICATION', message_id.upcase, 'a' * 19, 'a' * 65,
     "#{message_id}\n", "#{message_id}/x", "#{message_id}.eml", nil].each do |value|
      expect(run(value)).to eq('rejected')
    end
    expect(requests).to be_empty
  end

  it 'どの受信箱にも一致しない宛先と受信ドメインの外の for は rejected で、ActionMailbox に何も書かない' do
    unknown = 'shop-990002@inbox.staging.toybaco.jp'
    expect(run(raw: raw_email(to: unknown, received_for: unknown))).to eq('rejected')
    expect(run(raw: raw_email(to: 'store-owner@shop.example.invalid', received_for: address.sub('inbox.staging', 'other')))).to eq('rejected')
    expect(ActionMailbox::InboundEmail.count).to eq(0)
  end

  it 'Message-ID の無い原本、上限を超える原本、受信 ENV・bucket の形が違う環境は rejected' do
    expect(run(raw: raw_email(message_header: nil))).to eq('rejected')
    large = s3_client
    large.stub_responses(:get_object, { body: 'x', content_length: reingest::MAX_BYTES + 1 })
    expect(reingest.run(message_id, environment: environment, client: large)).to eq('rejected')
    [environment.merge('RAILS_INBOUND_EMAIL_SERVICE' => 'relay'), environment.except('TOYBACO_INBOUND_EMAIL_BUCKET'),
     environment.merge('TOYBACO_INBOUND_EMAIL_BUCKET' => 'toybaco-staging-storage')].each do |env|
      expect(run(env: env)).to eq('rejected')
    end
    expect(ActionMailbox::InboundEmail.count).to eq(0)
  end

  it 'S3 の拒否などの失敗は failed で、例外の文は返さない' do
    denied = Aws::S3::Client.new(stub_responses: true, region: 'ap-northeast-1')
    denied.stub_responses(:get_object, 'AccessDenied')
    expect(reingest.run(message_id, environment: environment, client: denied)).to eq('failed')
  end

  context 'with rake' do
    around do |example|
      with_modified_env(environment.transform_keys(&:to_sym).merge(TOYBACO_OPS_ACTOR: nil, TOYBACO_OPS_SOURCE: nil)) { example.run }
    end

    before { allow(Toybaco::Ops::Audit).to receive(:around).and_yield }

    def invoke(value)
      task = Rake::Task['toybaco:inbound_email_reingest']
      task.reenable
      capture = StringIO.new
      previous = $stdout
      $stdout = capture
      begin
        task.invoke(value)
        status = 0
      rescue SystemExit => e
        status = e.status
      ensure
        $stdout = previous
      end
      [capture.string.lines, status]
    end

    it '出力は固定語の 1 行で、原本・宛先・件名を出さない。取り込めない結果は exit 1' do
      stored = s3_client("inbound/#{message_id}" => raw_email)
      empty = s3_client
      allow(Aws::S3::Client).to receive(:new).and_return(stored)
      key = Digest::SHA256.hexdigest(message_id)[0, 12]
      lines, status = invoke(message_id)
      expect(lines.grep(/\ATOYBACO_INBOUND_REINGEST /)).to eq(["TOYBACO_INBOUND_REINGEST result=ingested key=#{key}\n"])
      expect(status).to eq(0)
      expect(lines.join).not_to include(address, 'reingest fixture subject', '再投入の本文', 'customer@example.invalid')

      lines, status = invoke('../etc/passwd')
      expect([lines, status]).to eq([["TOYBACO_INBOUND_REINGEST result=rejected key=#{Digest::SHA256.hexdigest('../etc/passwd')[0, 12]}\n"], 1])
      allow(Aws::S3::Client).to receive(:new).and_return(empty)
      lines, status = invoke(message_id)
      expect([lines, status]).to eq([["TOYBACO_INBOUND_REINGEST result=not_found key=#{key}\n"], 1])
    end

    it '宛先へ解決される処理済みの行が残り宛先に Message が無い時は、stranded の固定語の 1 行で、run は失敗(exit 1)' do
      source = Toybaco::InboundEmail.ses_action_mailbox_source(content: raw_email, destination: address)
      ActionMailbox::InboundEmail.create_and_extract_message_id!(source).delivered!
      allow(Aws::S3::Client).to receive(:new).and_return(s3_client("inbound/#{message_id}" => raw_email))

      lines, status = invoke(message_id)
      expect([lines.grep(/\ATOYBACO_INBOUND_REINGEST /), status])
        .to eq([["TOYBACO_INBOUND_REINGEST result=stranded key=#{Digest::SHA256.hexdigest(message_id)[0, 12]}\n"], 1])
    end
  end
end
