# frozen_string_literal: true

require 'rails_helper'

# 店舗の管理者宛ての受信チャネルの案内(Toybaco::ChannelNoticeMailer)。運営宛ての OperationsMailer の宛先(To / Bcc)を混ぜない。
RSpec.describe Toybaco::ChannelNoticeMailer do
  let(:operations_env) do
    { 'TOYBACO_OPERATIONS_EMAIL' => 'ops@example.invalid', 'TOYBACO_OPERATIONS_ALERT_EMAIL' => 'ops-alert@example.invalid',
      'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'production' }
  end

  def notice(to)
    described_class.with(to: to, subject: '【トイバコ】件名', body: "本文の 1 行目\n本文の 2 行目").notice
  end

  it '宛先は params の to(店舗の管理者)だけで、運営の宛先や Cc・Bcc を足さない' do
    mail = with_modified_env(operations_env) { notice(%w[admin-a@example.invalid admin-b@example.invalid]).message }

    expect(mail.to).to eq(%w[admin-a@example.invalid admin-b@example.invalid])
    expect([mail.cc, mail.bcc, mail.reply_to]).to eq([nil, nil, nil])
    expect(mail.header.fields.map(&:name)).not_to include('Bcc', 'Cc')
    expect(mail.to_s).not_to include('ops@example.invalid', 'ops-alert@example.invalid')
    expect(mail.subject).to eq('【トイバコ】件名')
  end

  it '本文は text だけで、params の本文をそのまま入れる' do
    mail = notice(['admin@example.invalid']).message

    expect(mail.multipart?).to be(false)
    expect(mail.mime_type).to eq('text/plain')
    expect(mail.decoded).to include("本文の 1 行目\n本文の 2 行目")
  end

  it '送信の失敗は握りつぶさず、呼び出し側(TOYBACO_CHANNEL_NOTICE_FAILED と翌日の再送)へ上げる(上流の ApplicationMailer は握りつぶす)' do
    error = Net::SMTPSyntaxError.new(Net::SMTP::Response.parse('501 5.5.4 bad'))

    expect { described_class.new.send(:handle_smtp_exceptions, error) }.to raise_error(error)
    expect { ApplicationMailer.new.send(:handle_smtp_exceptions, error) }.not_to raise_error
  end
end
