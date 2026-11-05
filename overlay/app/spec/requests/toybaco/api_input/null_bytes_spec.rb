# frozen_string_literal: true

require 'rails_helper'

# staging の DAST(2026-11-03)で \u0000 の入力が 500 になった経路。text の列は pg の ArgumentError(string contains null byte)、
# jsonb の列は PG::UntranslatableCharacter で落ちていた。Api::V1::Accounts::BaseController の callback の先頭で、SQL を 1 文も流す前に
# 400 を返す。同じ経路の正しい入力、multipart の file の中の NUL、webhook の NUL は今のまま通る。
RSpec.describe 'Toybaco API null byte guard', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account, name: 'DAST 連絡先', email: 'dast-contact@example.invalid') }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:label) { create(:label, account: account, title: 'dast-label') }
  let(:canned_response) { create(:canned_response, account: account, short_code: 'dast-short', content: 'DAST 定型文') }
  let(:headers) { { 'api_access_token' => admin.access_token.token } }
  let(:base) { "/api/v1/accounts/#{account.id}" }
  let(:nul) { "dast\u0000value" }
  let(:since) { 1.week.ago.to_i.to_s }
  let(:upto) { Time.current.to_i.to_s }

  # 要求の間に流れた SQL の文(schema の読み込みは除く)。
  def sql_during(&)
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
    statements
  end

  def send_request(method, path, params, as_json, request_headers = headers)
    options = { headers: request_headers }
    options[:params] = params if params
    options[:as] = :json if as_json
    public_send(method, path, **options)
  end

  # 経路(DAST の 500 の表の順)・正しい入力・NUL を入れた入力。正しい入力の期待は status と主な欄。
  cases = [
    { name: 'POST inboxes', method: :post, path: ->(c) { "#{c.base}/inboxes" }, json: true,
      valid: ->(_c) { { name: 'DAST 受信箱', channel: { type: 'api' } } }, invalid: ->(c) { { name: c.nul, channel: { type: 'api' } } },
      status: 200, check: ->(_c, body) { [body['name'], 'DAST 受信箱'] } },
    { name: 'POST contacts', method: :post, path: ->(c) { "#{c.base}/contacts" }, json: true,
      valid: ->(_c) { { name: 'DAST 新規' } }, invalid: ->(c) { { name: c.nul } },
      status: 200, check: ->(_c, body) { [body.dig('payload', 'contact', 'name'), 'DAST 新規'] } },
    { name: 'POST contacts(jsonb の値)', method: :post, path: ->(c) { "#{c.base}/contacts" }, json: true,
      valid: ->(_c) { { name: 'DAST 属性', custom_attributes: { dast_key: 'value' } } },
      invalid: ->(c) { { name: 'DAST 属性', custom_attributes: { dast_key: c.nul } } },
      status: 200, check: ->(_c, body) { [body.dig('payload', 'contact', 'custom_attributes'), { 'dast_key' => 'value' }] } },
    { name: 'POST contacts(jsonb の鍵)', method: :post, path: ->(c) { "#{c.base}/contacts" }, json: true,
      valid: ->(_c) { { name: 'DAST 鍵', custom_attributes: { 'dast_key' => 'value' } } },
      invalid: ->(_c) { { name: 'DAST 鍵', custom_attributes: { "dast\u0000key" => 'value' } } },
      status: 200, check: ->(_c, body) { [body.dig('payload', 'contact', 'name'), 'DAST 鍵'] } },
    { name: 'PATCH contacts/{id}', method: :patch, path: ->(c) { "#{c.base}/contacts/#{c.contact.id}" }, json: true,
      valid: ->(_c) { { name: 'DAST 変更' } }, invalid: ->(c) { { name: c.nul } },
      status: 200, check: ->(_c, body) { [body.dig('payload', 'name'), 'DAST 変更'] } },
    { name: 'POST contacts/filter', method: :post, path: ->(c) { "#{c.base}/contacts/filter" }, json: true,
      valid: ->(_c) { { payload: [{ attribute_key: 'name', filter_operator: 'equal_to', values: ['DAST 連絡先'], query_operator: nil }] } },
      invalid: ->(c) { { payload: [{ attribute_key: 'name', filter_operator: 'equal_to', values: [c.nul], query_operator: nil }] } },
      status: 200, check: ->(c, body) { [body['payload'].pluck('id'), [c.contact.id]] } },
    { name: 'GET conversations/search', method: :get, path: ->(c) { "#{c.base}/conversations/search" }, json: false,
      valid: ->(_c) { { q: 'DAST' } }, invalid: ->(c) { { q: c.nul } },
      status: 200, check: ->(_c, body) { [body.dig('meta', 'all_count').class, Integer] } },
    { name: 'POST canned_responses', method: :post, path: ->(c) { "#{c.base}/canned_responses" }, json: true,
      valid: ->(_c) { { canned_response: { short_code: 'dast-new', content: 'DAST 本文' } } },
      invalid: ->(c) { { canned_response: { short_code: c.nul, content: 'DAST 本文' } } },
      status: 200, check: ->(_c, body) { [body['short_code'], 'dast-new'] } },
    { name: 'PATCH canned_responses/{id}', method: :patch, path: ->(c) { "#{c.base}/canned_responses/#{c.canned_response.id}" }, json: true,
      valid: ->(_c) { { canned_response: { content: 'DAST 変更' } } }, invalid: ->(c) { { canned_response: { content: c.nul } } },
      status: 200, check: ->(_c, body) { [body['content'], 'DAST 変更'] } },
    { name: 'POST custom_filters(jsonb)', method: :post, path: ->(c) { "#{c.base}/custom_filters" }, json: true,
      valid: ->(_c) { { custom_filter: { name: 'DAST 絞り込み', type: 'conversation', query: { payload: [{ values: ['open'] }] } } } },
      invalid: ->(c) { { custom_filter: { name: 'DAST 絞り込み', type: 'conversation', query: { payload: [{ values: [c.nul] }] } } } },
      status: 200, check: ->(_c, body) { [body['query'], { 'payload' => [{ 'values' => ['open'] }] }] } },
    { name: 'POST labels', method: :post, path: ->(c) { "#{c.base}/labels" }, json: true,
      valid: ->(_c) { { label: { title: 'dast-new' } } }, invalid: ->(c) { { label: { title: c.nul } } },
      status: 200, check: ->(_c, body) { [body['title'], 'dast-new'] } },
    { name: 'PATCH labels/{id}', method: :patch, path: ->(c) { "#{c.base}/labels/#{c.label.id}" }, json: true,
      valid: ->(_c) { { label: { description: 'DAST 説明' } } }, invalid: ->(c) { { label: { description: c.nul } } },
      status: 200, check: ->(_c, body) { [body['description'], 'DAST 説明'] } },
    { name: 'POST contacts/{id}/notes', method: :post, path: ->(c) { "#{c.base}/contacts/#{c.contact.id}/notes" }, json: true,
      valid: ->(_c) { { note: { content: 'DAST メモ' } } }, invalid: ->(c) { { note: { content: c.nul } } },
      status: 200, check: ->(_c, body) { [body['content'], 'DAST メモ'] } },
    { name: 'GET search/conversations', method: :get, path: ->(c) { "#{c.base}/search/conversations" }, json: false,
      valid: ->(_c) { { q: 'DAST' } }, invalid: ->(c) { { q: c.nul } },
      status: 200, check: ->(_c, body) { [body['payload'].keys, ['conversations']] } },
    { name: 'GET reports(v2)', method: :get, path: ->(c) { "/api/v2/accounts/#{c.account.id}/reports" }, json: false,
      valid: ->(c) { { type: 'account', metric: 'conversations_count', since: c.since, until: c.upto } },
      invalid: ->(c) { { type: 'account', metric: 'conversations_count', since: c.nul, until: c.upto } },
      status: 200, check: ->(_c, body) { [body.class, Array] } }
  ].freeze

  cases.each do |example|
    context example[:name] do
      it 'NUL を含む入力は SQL を流す前に 400 を返し、行を作らない' do
        # 経路・入力・token の読み込み(連絡先などの作成を含む)の SQL を、数える要求の外で済ませる。
        path = example[:path].call(self)
        params = example[:invalid].call(self)
        request_headers = headers
        counts = -> { [Inbox, Channel::Api, Contact, CannedResponse, CustomFilter, Label, Note].map(&:count) }
        before_counts = counts.call
        statements = sql_during { send_request(example[:method], path, params, example[:json], request_headers) }
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('error' => Toybaco::Security::ApiInputGuard::NullBytes::MESSAGE)
        expect(statements).to eq([])
        expect(counts.call).to eq(before_counts)
      end

      it '正しい入力は今の応答を返す' do
        send_request(example[:method], example[:path].call(self), example[:valid].call(self), example[:json])
        expect(response).to have_http_status(example[:status])
        actual, expected = example[:check].call(self, response.parsed_body)
        expect(actual).to eq(expected)
      end
    end
  end

  it 'path の NUL も 400 にする' do
    get "#{base}/labels/dast%00value", headers: headers
    expect(response).to have_http_status(:bad_request)
  end

  it 'NUL を含む変更の要求は、連絡先の名前を変えない' do
    patch "#{base}/contacts/#{contact.id}", params: { name: nul }, headers: headers, as: :json
    expect(response).to have_http_status(:bad_request)
    expect(contact.reload.name).to eq('DAST 連絡先')
  end

  it 'multipart の file の中の NUL は照らさない(添付つきの送信は今のまま通る)' do
    path = Rails.root.join('spec/assets/avatar.png')
    expect(File.binread(path)).to include("\0")
    expect do
      post "#{base}/conversations/#{conversation.display_id}/messages",
           params: { content: 'DAST 添付', attachments: [fixture_file_upload(path, 'image/png')] }, headers: headers
    end.to change(Attachment, :count).by(1)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['content']).to eq('DAST 添付')
  end

  it 'webhook の経路の NUL は照らさない(Api::V1::Accounts::BaseController の子ではない)' do
    post '/webhooks/telegram/dast-bot-token', params: { message: { text: nul } }, as: :json
    expect(response).to have_http_status(:ok)
  end
end
