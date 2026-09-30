# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Browser session upload and public widget boundaries', type: :request do
  let(:account) { create(:account) }
  let(:widget) { create(:channel_widget, account: account) }
  let(:user) { create(:user, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: widget.inbox) }
  let(:conversation) { create(:conversation, account: account, inbox: widget.inbox, contact_inbox: contact_inbox, contact: contact) }
  let(:staff_headers) { { 'Origin' => 'https://chatwoot.test', 'X-Toybaco-Browser' => '1', 'Sec-Fetch-Site' => 'same-origin' } }

  before do
    host! 'chatwoot.test'
    https!
  end

  def staff_csrf
    get '/toybaco/browser-session', headers: staff_headers
    response.parsed_body.fetch('csrf_token')
  end

  def upload(headers)
    post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/direct_uploads",
         params: { blob: { filename: 'synthetic.txt', byte_size: 4, checksum: '1B2M2Y8AsgTpgAmY7PhCfg==', content_type: 'text/plain' } },
         headers: headers, as: :json
  end

  it 'uploads from the staff HttpOnly session only with CSRF' do
    cookies['cw_d_session_info'] = user.create_new_auth_token.to_json
    upload(staff_headers)
    expect(response).to have_http_status(:forbidden)
    upload(staff_headers.merge('X-CSRF-Token' => staff_csrf))
    expect(response).to have_http_status(:success)
    expect(response.parsed_body['filename']).to eq('synthetic.txt')
    expect(response.headers['access-token']).to be_nil
  end

  it 'preserves public widget JWT authentication across customer origins' do
    token = Widget::TokenService.new(payload: { source_id: contact_inbox.source_id, inbox_id: widget.inbox.id }).generate_token
    patch '/api/v1/widget/contact', params: { website_token: widget.website_token, name: 'Synthetic visitor' },
                                    headers: { 'Origin' => 'https://customer.example.test', 'X-Auth-Token' => token }, as: :json
    expect(response).to have_http_status(:success)
    expect(contact.reload.name).to eq('Synthetic visitor')
  end

  it 'does not grant widget access from the staff cookie alone or expire that separate cookie' do
    cookies['cw_d_session_info'] = user.create_new_auth_token.to_json
    original = cookies['cw_d_session_info']
    patch '/api/v1/widget/contact', params: { website_token: widget.website_token }, headers: staff_headers, as: :json
    expect(response).to have_http_status(:not_found)
    expect(cookies['cw_d_session_info']).to eq(original)
  end

  it 'keeps add-account credentials server-issued and usable without exposing bearer headers' do
    allow(GlobalConfigService).to receive(:account_signup_enabled?).and_return(true)
    allow(ChatwootCaptcha).to receive(:new).and_return(instance_double(ChatwootCaptcha, valid?: true))
    cookies['cw_d_session_info'] = user.create_new_auth_token.to_json
    post '/api/v1/accounts', params: { account_name: 'Synthetic additional account' },
                             headers: staff_headers.merge('X-CSRF-Token' => staff_csrf), as: :json
    expect(response).to have_http_status(:success)
    expect(user.reload.accounts.count).to eq(2)
    %w[access-token client uid authorization].each { |header| expect(response.headers[header]).to be_nil }
    expect(Array(response.headers['Set-Cookie']).join).to match(/cw_d_session_info=.*httponly/i)
    get '/api/v1/profile', headers: staff_headers
    expect(response).to have_http_status(:success)
    expect(response.parsed_body['id']).to eq(user.id)
  end
end
