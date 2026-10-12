# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/toybaco/growth/automated_mail')

# 段 2a: 一斉配信・自動送信・配信不能・noreply の見分けに使うヘッダーを、受信メールの content_attributes['email']['headers'] に
# 小文字のキーで残す(MailPresenter#headers_data への prepend)。from・auto-submitted・x-autoreply は生値。upstream の 3 つの
# 形は変えず、ほかのヘッダーは残さない。
RSpec.describe Toybaco::MailPresenterHeaders do
  def fixture(headers = {})
    mail = Mail.new
    mail.from = 'news@example.test'
    mail.to = 'store@example.test'
    mail.subject = 'お知らせ'
    mail.message_id = "<#{SecureRandom.hex(8)}@example.test>"
    mail.body = '今月のお知らせです。'
    headers.each { |name, value| mail[name] = value }
    mail
  end

  def headers_of(headers)
    MailPresenter.new(fixture(headers)).serialized_data[:headers]
  end

  it 'MailPresenter に当たっている' do
    expect(MailPresenter.ancestors).to include(described_class)
  end

  # 空の Return-Path(<>)は Mail が空の値として読む(AutomatedMail は '' も <> も空として扱う)。
  it '判定に使うヘッダーを小文字のキーで足し、upstream の 3 つはそのまま、ほかのヘッダーは入れない' do
    expect(headers_of('List-Unsubscribe' => '<mailto:leave@example.test>', 'List-Id' => '<news.example.test>', 'Precedence' => 'bulk',
                      'Return-Path' => '<>', 'X-Failed-Recipients' => 'gone@example.test', 'X-Auto-Response-Suppress' => 'All',
                      'Auto-Submitted' => 'auto-generated', 'X-Autoreply' => 'YES',
                      'X-Original-From' => 'original@example.test', 'X-Mailer' => 'Newsletter 1.0', 'List-Post' => 'NO')).to eq(
                        'x-original-from' => 'original@example.test', 'from' => 'news@example.test',
                        'auto-submitted' => 'auto-generated', 'x-autoreply' => 'YES',
                        'list-unsubscribe' => '<mailto:leave@example.test>', 'list-id' => '<news.example.test>',
                        'precedence' => 'bulk', 'return-path' => '', 'x-failed-recipients' => 'gone@example.test',
                        'x-auto-response-suppress' => 'All'
                      )
  end

  it '判定に使うヘッダーが From だけのメールは、From の生値と upstream の 3 つだけを残す' do
    expect(headers_of({})).to eq('from' => 'news@example.test')
    expect(headers_of('X-Original-Sender' => 'sender@example.test', 'X-Forwarded-For' => 'store@example.test')).to eq(
      'from' => 'news@example.test', 'x-original-sender' => 'sender@example.test', 'x-forwarded-for' => 'store@example.test'
    )
  end

  it '値は文字列にして 1 つ 500 文字で切る' do
    expect(headers_of('List-Id' => "<#{'a' * 600}.example.test>")['list-id'].length).to eq(500)
  end

  it '取り込んだメッセージの content_attributes に残る(Gmail・Microsoft・IMAP の取り込みが通る Imap::ImapMailbox)' do
    account = create(:account)
    channel = create(:channel_email, account: account)
    Imap::ImapMailbox.new.process(fixture('List-Unsubscribe' => '<mailto:leave@example.test>', 'Precedence' => 'list'), channel)
    message = channel.inbox.messages.order(:id).last
    expect(message.content_attributes.dig('email', 'headers')).to eq(
      'from' => 'news@example.test', 'list-unsubscribe' => '<mailto:leave@example.test>', 'precedence' => 'list'
    )
    expect(Toybaco::Growth::AutomatedMail.reason(message)).to eq('reason' => 'automated_mail', 'kind' => 'bulk')
  end

  # upstream の email.from・連絡先は Reply-To を優先し、email.auto_reply は 'no' / 'yes' と大小文字まで一致で判定する。
  # 取り込み(Imap::ImapMailbox → MailPresenter)を通したメールで、生値の判定が優先されることを確かめる。
  describe '取り込みを通したメールの判定' do
    def ingested(headers)
      channel = create(:channel_email, account: create(:account))
      Imap::ImapMailbox.new.process(fixture(headers), channel)
      channel.inbox.messages.order(:id).last
    end

    it 'From が noreply で Reply-To が普通のアドレスでも、元の From の生値で noreply と判定する' do
      message = ingested('From' => 'No Reply <No-Reply@example.test>', 'Reply-To' => 'support@example.test')
      expect(message.content_attributes.dig('email', 'from')).to eq(['support@example.test'])
      expect(message.sender.email).to eq('support@example.test')
      expect(message.content_attributes.dig('email', 'headers', 'from')).to eq('No Reply <No-Reply@example.test>')
      expect(Toybaco::Growth::AutomatedMail.reason(message)).to eq('reason' => 'automated_mail', 'kind' => 'noreply')
    end

    it 'X-Autoreply: YES は自動送信、Auto-Submitted: No は普通のメール(upstream の auto_reply より生値を優先する)' do
      yes = ingested('X-Autoreply' => 'YES')
      expect(yes.content_attributes.dig('email', 'auto_reply')).to be(false)
      expect(Toybaco::Growth::AutomatedMail.reason(yes)).to eq('reason' => 'automated_mail', 'kind' => 'auto_submitted')

      no = ingested('Auto-Submitted' => 'No')
      expect(no.content_attributes.dig('email', 'auto_reply')).to be(true)
      expect(Toybaco::Growth::AutomatedMail.reason(no)).to be_nil
    end
  end
end
