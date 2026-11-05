# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Immediate legacy widget cutoff', type: :request do
  let(:widget) { create(:channel_widget) }
  let(:legacy_link) { create(:contact_inbox, inbox: widget.inbox, contact: create(:contact, account: widget.account)) }
  let(:legacy) { Widget::TokenService.new(payload: { inbox_id: widget.inbox.id, source_id: legacy_link.source_id }).generate_token }
  let(:headers) { { 'Origin' => 'https://chatwoot.test', 'X-Toybaco-Widget' => '1', 'Sec-Fetch-Site' => 'same-origin' } }

  before do
    host! 'chatwoot.test'
    https!
  end

  def bootstrap(token = nil, ephemeral: false)
    post '/api/v1/widget/http_session', params: { website_token: widget.website_token, legacy_token: token,
                                                  ephemeral: ephemeral, consume_intent: SecureRandom.hex(32) },
                                        headers: headers, as: :json
    response.parsed_body.fetch('proof')
  end

  it 'ignores a valid legacy body JWT and starts an unrelated anonymous visitor' do
    token = legacy
    bootstrap(token)
    expect(response).to have_http_status(:ok)
    expect(Toybaco::WidgetSessionRecord.last.contact_inbox_id).not_to eq(legacy_link.id)
    expect(response.body).not_to include(token)
    expect(legacy_link.reload.source_id).to eq(Widget::TokenService.new(token: token).decode_token[:source_id])
  end

  it 'keeps the current-protocol HttpOnly visitor regardless of a legacy body JWT' do
    token = legacy
    bootstrap
    original = Toybaco::WidgetSessionRecord.last
    proof = bootstrap(token)
    get '/api/v1/widget/contact', params: { website_token: widget.website_token }, headers: headers.merge('X-Auth-Token' => proof)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['id']).to eq(original.contact_inbox.contact_id)
    expect(Toybaco::WidgetSessionRecord.count).to eq(1)
  end

  it 'rejects a legacy header with or without a cookie' do
    token = legacy
    get '/api/v1/widget/messages', params: { website_token: widget.website_token }, headers: headers.merge('X-Auth-Token' => token)
    expect(response).to have_http_status(:not_found)
    bootstrap
    get '/api/v1/widget/messages', params: { website_token: widget.website_token }, headers: headers.merge('X-Auth-Token' => token)
    expect(response).to have_http_status(:not_found)
  end

  it 'isolates explicit ephemeral API requests without leaving a cookie or exposing previous history', :aggregate_failures do
    old_proof = bootstrap
    previous = Toybaco::WidgetSessionRecord.last
    previous_link = previous.contact_inbox
    previous_link.contact.update!(email: 'previous@example.test')
    conversation = create(:conversation, account: widget.account, inbox: widget.inbox,
                                         contact_inbox: previous_link, contact: previous_link.contact)
    message = create(:message, account: widget.account, inbox: widget.inbox, conversation: conversation, content: 'Previous private history')
    recovery = Toybaco::Security::WidgetHttpSession.recovery_token(previous, expires_at: 1.minute.from_now)
    proof = bootstrap('surviving-domain-cookie', ephemeral: true)
    fresh = Toybaco::WidgetSessionRecord.last
    expect(response.parsed_body['persisted']).to be(false)
    expect(proof).to start_with('tbwr1.')
    expect(previous.reload.revoked_at).to be_present
    expect(fresh.id).not_to eq(previous.id)
    expect(fresh.contact_inbox_id).not_to eq(previous_link.id)
    expect(fresh.contact_inbox.contact_id).not_to eq(previous_link.contact_id)
    expect(fresh.expires_at).to be <= 2.hours.from_now
    expect(fresh.persisted_at).to be_nil
    expect(cookies[Toybaco::Security::WidgetHttpSession.cookie_name(widget)]).to be_blank
    expect(response.headers['Clear-Site-Data']).to be_nil
    get '/api/v1/widget/contact', params: { website_token: widget.website_token }, headers: headers.merge('X-Auth-Token' => proof)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['id']).to eq(fresh.contact_inbox.contact_id)
    expect(response.parsed_body['email']).not_to eq('previous@example.test')
    get '/api/v1/widget/messages', params: { website_token: widget.website_token }, headers: headers.merge('X-Auth-Token' => proof)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['payload']).to be_empty
    [old_proof, recovery].each do |old|
      get '/api/v1/widget/contact', params: { website_token: widget.website_token }, headers: headers.merge('X-Auth-Token' => old)
      expect(response).to have_http_status(:not_found)
      get '/api/v1/widget/messages', params: { website_token: widget.website_token }, headers: headers.merge('X-Auth-Token' => old)
      expect(response).to have_http_status(:not_found)
    end
    bootstrap('surviving-domain-cookie', ephemeral: true)
    expect(Toybaco::WidgetSessionRecord.last.contact_inbox_id).not_to eq(fresh.contact_inbox_id)
    expect(cookies[Toybaco::Security::WidgetHttpSession.cookie_name(widget)]).to be_blank
    bootstrap
    expect(Toybaco::WidgetSessionRecord.last.contact_inbox_id).not_to eq(fresh.contact_inbox_id)
    expect(message.reload.content).to eq('Previous private history')
    expect(conversation.reload.contact_id).to eq(previous_link.contact_id)
  end

  it 'keeps signed re-identification in memory for a nonpersistent visitor' do
    proof = bootstrap(ephemeral: true)
    row = Toybaco::WidgetSessionRecord.last
    expiry = row.expires_at
    signature = OpenSSL::HMAC.hexdigest('sha256', widget.hmac_token, 'verified-visitor')
    patch '/api/v1/widget/contact/set_user', params: { website_token: widget.website_token, identifier: 'verified-visitor',
                                                       identifier_hash: signature }, headers: headers.merge('X-Auth-Token' => proof), as: :json
    expect(response).to have_http_status(:ok)
    next_proof = response.parsed_body.fetch('widget_auth_token')
    expect(next_proof).to start_with('tbwr1.')
    expect(row.reload.expires_at).to eq(expiry)
    expect(cookies[Toybaco::Security::WidgetHttpSession.cookie_name(widget)]).to be_blank
    get '/api/v1/widget/contact', params: { website_token: widget.website_token }, headers: headers.merge('X-Auth-Token' => next_proof)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['identifier']).to eq('verified-visitor')
  end

  ['random-cw-conversation-value', 'forged.jwt.signature'].each do |value|
    it "resumes only the current-protocol browser cookie when the ignored legacy value is #{value}" do
      bootstrap
      own = Toybaco::WidgetSessionRecord.last
      foreign = legacy_link
      proof = bootstrap(value)
      get '/api/v1/widget/contact', params: { website_token: widget.website_token }, headers: headers.merge('X-Auth-Token' => proof)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['id']).to eq(own.contact_inbox.contact_id)
      expect(response.parsed_body['id']).not_to eq(foreign.contact_id)
      expect(Toybaco::WidgetSessionRecord.count).to eq(1)
    end
  end

  it 'does not create a contact or issue a JWT through config without a proof' do
    widget
    expect(Widget::TokenService).not_to receive(:new)
    expect do
      post '/api/v1/widget/config', params: { website_token: widget.website_token }, headers: headers, as: :json
    end.not_to change(ContactInbox, :count)
    expect(response).to have_http_status(:not_found)
  end

  it 'returns only an HTTP proof from config and identity switching without generating a JWT' do
    proof = bootstrap
    Toybaco::WidgetSessionRecord.last.contact_inbox.contact.update!(identifier: 'old-visitor')
    expect(Widget::TokenService).not_to receive(:new)
    post '/api/v1/widget/config', params: { website_token: widget.website_token }, headers: headers.merge('X-Auth-Token' => proof), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('website_channel_config', 'auth_token')).to start_with('tbwp1.')
    patch '/api/v1/widget/contact/set_user', params: { website_token: widget.website_token, identifier: 'new-visitor' },
                                             headers: headers.merge('X-Auth-Token' => proof), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['widget_auth_token']).to start_with('tbwp1.')
  end

  it 'consumes a verified handoff without generating a legacy JWT' do
    proof = bootstrap
    post '/api/v1/widget/http_session/handoff', params: { website_token: widget.website_token },
                                                headers: headers.merge('X-Auth-Token' => proof), as: :json
    code = response.parsed_body.fetch('code')
    cookies.delete(Toybaco::Security::WidgetHttpSession.cookie_name(widget))
    expect(Widget::TokenService).not_to receive(:new)
    post '/api/v1/widget/http_session/consume', params: { website_token: widget.website_token, handoff_code: code,
                                                          consume_intent: SecureRandom.hex(32) }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(Toybaco::WidgetSessionRecord.distinct.count(:contact_inbox_id)).to eq(1)
    expect(response.parsed_body['proof']).to start_with('tbwp1.')
  end
end
