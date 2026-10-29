# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::Security::InstagramSendLog do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_instagram, account: account, instagram_id: 'fixture-instagram') }
  let(:inbox) { create(:inbox, channel: channel, account: account, greeting_enabled: false) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) { create(:conversation, account: account, contact: contact, inbox: inbox, contact_inbox: contact_inbox) }
  let(:body) { "Instagram 本文 #{SecureRandom.hex(8)}" }
  let(:attachment_url) { "https://attachments.example.test/private/#{SecureRandom.hex(16)}" }
  let(:message) { create(:message, message_type: :outgoing, account: account, inbox: inbox, conversation: conversation, content: body) }
  let(:service) { Instagram::SendOnInstagramService.new(message: message) }

  def capture_application_log
    io = StringIO.new
    sink = ActiveSupport::Logger.new(io).tap { |logger| logger.level = :info }
    Rails.logger.broadcast_to(sink)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(sink)
  end

  def rejected_response(code, success: false)
    # provider の説明が入力本文や URL を反射しても、ログは code だけを出す。
    parsed = { 'error' => { 'code' => code, 'message' => "Rejected #{body} #{attachment_url}" } }
    instance_double(HTTParty::Response, success?: success, parsed_response: parsed)
  end

  it '拒否された本文・添付の送信は ID と provider code だけを記録し、failed と再認証の扱いを変えない' do
    attachment = message.attachments.new(account_id: account.id, file_type: :image)
    attachment.file.attach(io: Rails.root.join('spec/assets/avatar.png').open, filename: 'avatar.png', content_type: 'image/png')
    message.save!
    # 配送は送る前に message を読み直すので、添付の URL は HTTParty に実際に渡った値で検査する。
    sent = []
    allow(HTTParty).to receive(:post) do |_url, options|
      sent << options[:body][:message]
      rejected_response(190)
    end
    result = nil

    log = capture_application_log { result = service.perform }

    sent_url = sent.filter_map { |item| item.dig(:attachment, :payload, :url) }.sole
    expect(sent_url).to include('/rails/active_storage/')
    expect(sent).to contain_exactly({ text: body }, { attachment: { type: 'image', payload: { url: sent_url } } })
    expect(result).to be_nil
    expect(message.reload.status).to eq('failed')
    expect(message.external_error).to eq("190 - Rejected #{body} #{attachment_url}")
    expect(channel.reload).to be_reauthorization_required
    # 2 回とも ID と code だけが出て、本文・送った添付の URL・provider の説明はどこにも出ない。
    expect([log.scan("Instagram send failed message_id=#{message.id} account_id=#{account.id} code=190").size,
            [body, sent_url, attachment_url, 'Rejected'].select { |value| log.include?(value) }]).to eq([2, []])
  end

  it 'HTTP success でも provider error があれば失敗にし、不正または長すぎる code はログに出さない' do
    ["#{body} #{attachment_url}", '1' * 100, nil].each do |code|
      response = rejected_response(code, success: true)
      log = capture_application_log { expect(service.send(:process_response, response, { text: body })).to be_nil }
      expect(log).to include("Instagram send failed message_id=#{message.id} account_id=#{account.id} code=[unknown]")
      expect([body, attachment_url, '1' * 100].select { |value| log.include?(value) }).to eq([])
      expect(message.reload.status).to eq('failed')
      expect(message.external_error).to eq("#{code} - Rejected #{body} #{attachment_url}")
    end
  end

  it '成功時の source_id 更新と parsed response の返却を維持する' do
    parsed = { 'message_id' => 'fixture-message-id' }
    response = instance_double(HTTParty::Response, success?: true, parsed_response: parsed)
    log = capture_application_log { expect(service.send(:process_response, response, { text: body })).to eq(parsed) }
    expect(message.reload.source_id).to eq('fixture-message-id')
    expect(message.status).not_to eq('failed')
    expect(log).not_to include('Instagram send failed', body)
  end
end
