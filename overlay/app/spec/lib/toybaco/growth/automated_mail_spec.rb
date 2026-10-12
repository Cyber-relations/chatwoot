# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/toybaco/growth/automated_mail')

# 段 2a: 一斉配信・自動送信・配信不能・noreply のメールには、AI が自動で返信しない。判定はメールの窓口の受信だけで、
# 保存したメールの情報(content_attributes['email'])と送り手のメールアドレスから行う。
RSpec.describe Toybaco::Growth::AutomatedMail do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_email, account: account)) }
  let(:contact) { create(:contact, account: account, email: 'customer@example.test') }

  # email は保存したメールの情報(content_attributes['email'])。options は target(窓口)・sender(送り手)・message_type。
  def mail_message(email = {}, options = {})
    target = options.fetch(:target, inbox)
    sender = options.fetch(:sender, contact)
    conversation = create(:conversation, account: account, inbox: target, contact: sender)
    create(:message, account: account, inbox: target, conversation: conversation, sender: sender,
                     message_type: options.fetch(:message_type, :incoming), private: false, content: 'お問い合わせです',
                     content_attributes: { email: email })
  end

  def kind_of(email, options = {})
    described_class.reason(mail_message(email, options))&.fetch('kind')
  end

  it '普通のお客さまのメールは除外しない' do
    email = { 'from' => ['customer@example.test'], 'auto_reply' => false, 'content_type' => 'multipart/alternative',
              'headers' => { 'x-original-from' => 'a@b.test' } }
    expect(described_class.reason(mail_message(email))).to be_nil
  end

  it '自動送信(Auto-Submitted が no 以外・X-Autoreply: yes・X-Auto-Response-Suppress・Precedence: auto_reply)を除外する' do
    expect(described_class.reason(mail_message('auto_reply' => true))).to eq('reason' => 'automated_mail', 'kind' => 'auto_submitted')
    [{ 'Auto-Submitted' => 'auto-replied' }, { 'auto-submitted' => ['auto-generated'] }, { 'AUTO-SUBMITTED' => '' },
     { 'X-Autoreply' => 'YES' }, { 'x-auto-response-suppress' => 'All' }, { 'Precedence' => 'Auto_Reply' },
     { 'Precedence' => '"auto_reply"' }].each do |headers|
      expect(kind_of('headers' => headers)).to eq('auto_submitted'), headers.inspect
    end
    [{ 'Auto-Submitted' => 'no' }, { 'auto-submitted' => [' No '] }, { 'X-Autoreply' => 'no' }].each do |headers|
      expect(kind_of('headers' => headers)).to be_nil, headers.inspect
    end
  end

  it '一斉配信(List-Unsubscribe・List-Id・Precedence: bulk / list / junk)を除外する' do
    [{ 'List-Unsubscribe' => '<mailto:leave@example.test>' }, { 'list-id' => ['<news.example.test>'] },
     { 'Precedence' => 'bulk' }, { 'precedence' => 'LIST' }, { 'PRECEDENCE' => [' junk '] },
     { 'Precedence' => '"bulk"' }, { 'Precedence' => '(list)' }, { 'Precedence' => ' Bulk ' }].each do |headers|
      expect(kind_of('headers' => headers)).to eq('bulk'), headers.inspect
    end
    # Precedence は引用符・括弧・前後の空白を除いた先頭の語で比べる。ほかの語は除外しない。
    [{ 'Precedence' => 'first-class', 'List-Post' => '<mailto:post@example.test>' }, { 'Precedence' => '(normal)' },
     { 'Precedence' => '"bulky"' }].each do |headers|
      expect(kind_of('headers' => headers)).to be_nil, headers.inspect
    end
  end

  it '配信不能の通知(mailer-daemon@・postmaster@・Return-Path が空・X-Failed-Recipients・multipart/report)を除外する' do
    daemon = create(:contact, account: account, email: 'MAILER-DAEMON@mail.example.test')
    expect(kind_of({}, sender: daemon)).to eq('bounce')
    expect(kind_of('from' => ['postmaster@example.test'])).to eq('bounce')
    [{ 'Return-Path' => '<>' }, { 'return-path' => [' < > '] }, { 'X-Failed-Recipients' => 'gone@example.test' }].each do |headers|
      expect(kind_of('headers' => headers)).to eq('bounce'), headers.inspect
    end
    expect(kind_of('content_type' => 'multipart/report; report-type=delivery-status')).to eq('bounce')
    expect(kind_of('headers' => { 'Return-Path' => '<customer@example.test>' }, 'content_type' => 'multipart/mixed')).to be_nil
    expect(kind_of('from' => ['daemon-fan@example.test', 'postmaster.office@example.test'])).to be_nil
  end

  it 'noreply の送り手(区切りの - _ . と大小文字、+ 以降を問わない)を除外する' do
    %w[noreply@example.test No-Reply@example.test no_reply@example.test DoNotReply@example.test do-not-reply@example.test
       do.not.reply@example.test noreply+news@example.test].each do |address|
      expect(kind_of('from' => [address])).to eq('noreply'), address
    end
    noreply = create(:contact, account: account, email: 'no-reply@shop.example.test')
    expect(kind_of({}, sender: noreply)).to eq('noreply')
    %w[reply@example.test norelay@example.test noreply-team-lead@example.test info@noreply.example.test].each do |address|
      expect(kind_of('from' => [address])).to be_nil, address
    end
  end

  it 'メールの窓口の受信だけを判定する' do
    web = create(:inbox, account: account)
    expect(described_class.reason(mail_message({ 'auto_reply' => true }, target: web))).to be_nil
    expect(described_class.reason(mail_message({ 'auto_reply' => true }, message_type: :outgoing))).to be_nil
    expect(described_class.reason(nil)).to be_nil
    expect(described_class.reason(mail_message({ 'headers' => 'List-Id: broken', 'from' => 'noreply@example.test' }))).to eq(
      'reason' => 'automated_mail', 'kind' => 'noreply'
    )
  end
end
