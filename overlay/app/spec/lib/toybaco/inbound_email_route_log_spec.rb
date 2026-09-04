# frozen_string_literal: true

require 'rails_helper'

# SES ingress の create_and_extract_message_id! は Rails 過程で必ず走る。
# RoutingJob 側だけのログだと token 行に SupportMailbox が載らない。
RSpec.describe Toybaco::InboundEmail do
  let(:token) { 'cafef00d' }
  let(:destination) { 'shop-1@inbox.staging.toybaco.jp' }
  let(:fixture_source) do
    [
      'From: Fixture Sender <fixture-sender@example.invalid>',
      "To: #{destination}",
      "Delivered-To: #{destination}",
      "X-Original-To: #{destination}",
      'Subject: toybaco inbound fixture',
      'Message-ID: <rewritten@unknown.host>',
      "X-Toybaco-Fixture: toybaco-fixture-#{token}",
      'MIME-Version: 1.0',
      'Content-Type: text/plain; charset=UTF-8',
      '',
      'fixture'
    ].join("\r\n")
  end

  it 'ingress の原本から mailbox=SupportMailbox と Conversation と token を同じ行へ出す' do
    line = described_class.log_ingress_mailbox_route(fixture_source, channel_found: true)

    expect(line).to include("toybaco-fixture-#{token}")
    expect(line).to include('mailbox=SupportMailbox')
    expect(line).to match(/Conversation=(yes|no)/)
    expect(line).not_to include("\n")
    expect(line).not_to match(/conversation_id=\d+/)
    expect(line).not_to include('fixture-sender')
  end
end
