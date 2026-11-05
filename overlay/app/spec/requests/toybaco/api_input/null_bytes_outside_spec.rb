# frozen_string_literal: true

require 'rails_helper'

# 第 1 回(null_bytes_spec)の残り: Api::V1::Accounts::BaseController の外の profile・店舗の作成と更新(v1・v2)・widget の
# API・公開 API にも、同じ NUL の照らし(SQL を流す前の 400)を入れる。webhook・受信のメール(SES)・Stripe・channel の
# callback・active_storage の direct upload は対象の外で、NUL があっても照らしは応答を作らない(今の応答のまま)。
RSpec.describe 'Toybaco API null byte guard outside the account API', type: :request do
  let(:account) { create(:account, name: 'DAST 店舗') }
  let(:admin) { create(:user, account: account, role: :administrator, name: 'DAST 管理者') }
  let(:headers) { { 'api_access_token' => admin.access_token.token } }
  let(:nul) { "dast\u0000value" }
  let(:message) { Toybaco::Security::ApiInputGuard::NullBytes::MESSAGE }

  def sql_during(&)
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
    statements
  end

  def guard_response?
    response.status == 400 && (response.parsed_body rescue nil) == { 'error' => message } # rubocop:disable Style/RescueModifier
  end

  describe '照らす経路' do
    it 'NUL を含む入力は SQL を流す前に 400 を返す' do
      request_headers = headers
      requests = [
        [:patch, '/api/v1/profile', { profile: { name: nul } }, request_headers],
        [:post, '/api/v1/accounts', { account_name: nul, email: 'dast-signup@example.invalid' }, {}],
        [:patch, "/api/v1/accounts/#{account.id}", { name: nul }, request_headers],
        [:post, '/api/v2/accounts', { account_name: nul, email: 'dast-signup@example.invalid' }, {}],
        [:get, '/api/v1/widget/campaigns', { website_token: nul }, {}],
        [:post, "/public/api/v1/inboxes/#{CGI.escape(nul)}/contacts", { name: 'DAST' }, {}]
      ]
      requests.each do |method, path, params, extra_headers|
        statements = sql_during { public_send(method, path, params: params, headers: extra_headers, as: :json) }
        expect([path, response.status]).to eq([path, 400])
        expect(response.parsed_body).to eq('error' => message)
        expect([path, statements]).to eq([path, []])
      end
      expect([admin.reload.name, account.reload.name]).to eq(['DAST 管理者', 'DAST 店舗'])
    end

    it '正しい入力は今の応答を返す(profile と店舗の更新、知らない widget と公開 API の 404)' do
      patch '/api/v1/profile', params: { profile: { name: 'DAST 変更' } }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['name']).to eq('DAST 変更')

      patch "/api/v1/accounts/#{account.id}", params: { name: 'DAST 店舗の変更' }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(account.reload.name).to eq('DAST 店舗の変更')

      get '/api/v1/widget/campaigns', params: { website_token: 'dast-unknown' }
      expect(response).to have_http_status(:not_found)
      post '/public/api/v1/inboxes/dast-unknown/contacts', params: { name: 'DAST' }, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe '対象の外の経路(NUL があっても照らしは応答を作らない)' do
    let(:conversation) { create(:conversation, account: account) }
    let(:blob) { { blob: { filename: nul, byte_size: 4, checksum: 'r7uOU8YJKJ/F0EsTEi3s9Q==', content_type: 'text/plain' } } }

    it 'webhook・Stripe・channel の callback・direct upload' do
      requests = [
        [:post, '/webhooks/line/dast-channel', { events: [{ message: { text: nul } }] }, {}],
        [:post, '/webhooks/telegram/dast-bot-token', { message: { text: nul } }, {}],
        [:post, '/toybaco/webhooks/stripe/billing', { type: nul }, { 'Stripe-Signature' => 't=1,v1=dast' }],
        [:post, '/rails/active_storage/direct_uploads', blob, {}],
        [:post, "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/direct_uploads", blob, headers]
      ]
      requests.each do |method, path, params, extra_headers|
        public_send(method, path, params: params, headers: extra_headers, as: :json)
        expect([path, guard_response?]).to eq([path, false])
      end
    end

    it '受信のメール(SES の ingress)' do
      with_modified_env(MAILER_INBOUND_EMAIL_DOMAIN: 'inbox.staging.toybaco.jp', RAILS_INBOUND_EMAIL_SERVICE: 'ses',
                        ACTION_MAILBOX_SES_SNS_TOPIC: 'arn:aws:sns:ap-northeast-1:000000000000:toybaco-gate-inbound') do
        Rails.application.reload_routes!
        post Toybaco::InboundEmail::INGRESS_PATH, params: { Type: 'Notification', Message: nul }, as: :json
        expect(response.status).not_to eq(404)
        expect(guard_response?).to be(false)
      end
    ensure
      Rails.application.reload_routes!
    end
  end
end
