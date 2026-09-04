# frozen_string_literal: true

require 'rails_helper'

# FilterLogEvents は toybaco-fixture-<token> の行だけを見る。
# SupportMailbox が fixture を process したとき、同じ1行に mailbox 名と
# Conversation=yes|no が残っていなければ診断は no のままになる。
RSpec.describe SupportMailbox do
  include ActionMailbox::TestHelper

  let(:token) { 'cafef00d' }
  let(:destination) { 'shop-1@inbox.staging.toybaco.jp' }
  let(:fixture_source) do
    [
      'From: Fixture Sender <fixture-sender@example.invalid>',
      "To: #{destination}",
      "Delivered-To: #{destination}",
      "X-Original-To: #{destination}",
      'Subject: toybaco inbound fixture',
      "Message-ID: <toybaco-fixture-#{token}@inbox.staging.toybaco.jp>",
      "X-Toybaco-Fixture: toybaco-fixture-#{token}",
      'MIME-Version: 1.0',
      'Content-Type: text/plain; charset=UTF-8',
      '',
      'fixture'
    ].join("\r\n")
  end

  def combined_route_line?(text)
    line = text.to_s
    line.include?("toybaco-fixture-#{token}") &&
      line.include?('mailbox=SupportMailbox') &&
      line.match?(/Conversation=(yes|no)/)
  end

  it 'fixture mail を process した1行に token と mailbox=SupportMailbox と Conversation を残す' do
    inbound = create_inbound_email_from_source(fixture_source)
    mailbox = described_class.new(inbound)
    allow(mailbox).to receive(:find_conversation)
    messages = []
    allow(Rails.logger).to receive(:info).and_wrap_original do |method, *args|
      messages << args.first.to_s
      method.call(*args)
    end

    mailbox.perform_processing

    expect(messages.find { |line| combined_route_line?(line) }).to be_present
  end
end
