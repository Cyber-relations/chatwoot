# frozen_string_literal: true

require 'rails_helper'

# CASA 2.1.1・6.5.1: API 型の受信箱の client API の連絡先の identifier を、Rails の Started の行(LogScrub)と Parameters の行
# (filter_parameters。lograge も同じ filtered params を読む)に出さない。作成の POST の source_id も同じ identifier で、その値で
# 既存の連絡先につなぐ。本番と同じ INFO の行を見る(DEBUG の SQL の行は本番の log に出ない)。ほかの id は今のまま出す。
RSpec.describe 'Public inbox API contact identifier in request logs', type: :request do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_api, account: account) }
  let(:identifier) { "visitor-#{SecureRandom.hex(12)}" }

  before { create(:contact_inbox, inbox: channel.inbox, source_id: identifier) }

  def info_log
    io = StringIO.new
    sink = ActiveSupport::Logger.new(io)
    sink.level = Logger::INFO
    Rails.logger.broadcast_to(sink)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(sink) if sink
  end

  it 'masks the identifier in the path and in the parameters of the contact and conversation endpoints' do
    log = info_log do
      get "/public/api/v1/inboxes/#{channel.identifier}/contacts/#{identifier}"
      get "/public/api/v1/inboxes/#{channel.identifier}/contacts/#{identifier}/conversations"
    end

    expect(log).not_to include(identifier)
    expect(log.scan(%r{Started GET "/public/api/v1/inboxes/#{channel.identifier}/contacts/\[FILTERED\]}).size).to eq(2)
    expect(log.scan(/Parameters: .*"(?:id|contact_id)" ?=> ?"\[FILTERED\]"/).size).to eq(2)
    expect(log).to include(channel.identifier)
  end

  it 'masks the source_id of the contact creation in the log and in the params lograge reads, and still reconnects the contact' do
    logged_params = []
    callback = ->(event) { logged_params << event.payload[:params] }
    log = info_log do
      ActiveSupport::Notifications.subscribed(callback, 'process_action.action_controller') do
        post "/public/api/v1/inboxes/#{channel.identifier}/contacts", params: { source_id: identifier }, as: :json
      end
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['source_id']).to eq(identifier)
    expect(channel.inbox.contact_inboxes.where(source_id: identifier).count).to eq(1)
    expect(logged_params.map { |params| params['source_id'] }).to eq(['[FILTERED]'])
    expect(log).to match(/Parameters: .*"source_id" ?=> ?"\[FILTERED\]"/)
    expect([log, logged_params.to_s].select { |text| text.include?(identifier) }).to eq([])
  end

  it 'masks a source_id given in the query, in the Started line and in the path and params of the controller notifications' do
    payloads = []
    callback = ->(event) { payloads << event.payload.slice(:path, :params) }
    log = info_log do
      ActiveSupport::Notifications.subscribed(callback, /\A(?:start_processing|process_action)\.action_controller\z/) do
        post "/public/api/v1/inboxes/#{channel.identifier}/contacts?%73ource%5Fid=#{identifier}"
      end
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['source_id']).to eq(identifier)
    expect(log).to include(%(Started POST "/public/api/v1/inboxes/#{channel.identifier}/contacts?%73ource%5Fid=[FILTERED]"))
    expect(payloads.map { |payload| [payload[:path], payload[:params]['source_id']] })
      .to eq([["/public/api/v1/inboxes/#{channel.identifier}/contacts?%73ource%5Fid=[FILTERED]", '[FILTERED]']] * 2)
    expect([log, payloads.to_s].select { |text| text.include?(identifier) }).to eq([])
  end

  it 'still logs the ids of other endpoints' do
    user = create(:user, account: account, role: :administrator)
    contact = create(:contact, account: account)

    log = info_log { get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}", headers: user.create_new_auth_token }

    expect(log).to include(%(Started GET "/api/v1/accounts/#{account.id}/contacts/#{contact.id}"))
    expect(log).to match(/Parameters: .*"id" ?=> ?"#{contact.id}"/)
  end
end
