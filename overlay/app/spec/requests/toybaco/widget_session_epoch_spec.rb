# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget HTTP session security epoch', type: :request do
  include_context 'with a widget session established before the security epoch'
  let(:headers) { { 'Origin' => 'https://chatwoot.test', 'X-Toybaco-Widget' => '1', 'Sec-Fetch-Site' => 'same-origin' } }
  let(:conversation) { create(:conversation, account: widget.account, inbox: widget.inbox, contact: victim, contact_inbox: link) }
  let(:message) { create(:message, account: widget.account, inbox: widget.inbox, conversation: conversation, content: 'Pre-cutover private history') }

  before do
    host! 'chatwoot.test'
    https!
    cookies[cookie_name] = cookie
  end

  def read_widget(resource, credential)
    get "/api/v1/widget/#{resource}", params: { website_token: widget.website_token },
                                      headers: headers.merge('X-Auth-Token' => credential)
  end

  def post_session(action, parameters = {}, credential = proof)
    post "/api/v1/widget/http_session#{action}", params: { website_token: widget.website_token }.merge(parameters),
                                                 headers: headers.merge('X-Auth-Token' => credential), as: :json
  end

  def expect_empty_visitor(credential)
    read_widget('contact', credential)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['id']).not_to eq(victim.id)
    read_widget('messages', credential)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('payload')).to be_empty
  end

  resources = %w[contact messages]
  handoff_actions = { 'recovery' => '/recover', 'popout' => '/consume' }
  %i[legacy_jwt cross_visitor_merge].product(%i[environment persisted]).each do |origin, source|
    context "when a #{origin} session has been upgraded with a #{source} cutoff" do
      let(:establishment) { origin }
      let(:epoch_source) { source }

      it 'denies the prior profile and history with both HTTP and recovery proofs without deleting history' do
        message
        credentials = [proof, recovery]
        credentials.each do |credential|
          read_widget('contact', credential)
          expect(response.parsed_body['id']).to eq(victim.id)
          read_widget('messages', credential)
          expect(response.body).to include(message.content)
        end
        stub_epoch(cutoff)
        credentials.each do |credential|
          resources.each do |resource|
            read_widget(resource, credential)
            expect(response).to have_http_status(:not_found)
          end
        end
        expect(message.reload.content).to eq('Pre-cutover private history')
        expect(conversation.reload.contact_id).to eq(victim.id)
        expect(row.reload).not_to be_current
      end

      it 'denies profile changes and messages using an older cookie or recovery proof' do
        message
        credentials = [proof, recovery]
        stub_epoch(cutoff)
        credentials.each do |credential|
          authenticated_headers = headers.merge('X-Auth-Token' => credential)
          expect do
            patch '/api/v1/widget/contact', params: { website_token: widget.website_token, name: 'Rejected update' },
                                            headers: authenticated_headers, as: :json
          end.not_to(change { victim.reload.name })
          expect(response).to have_http_status(:not_found)
          expect do
            post '/api/v1/widget/messages', params: { website_token: widget.website_token, content: 'Rejected message' },
                                            headers: authenticated_headers, as: :json
          end.not_to change(Message, :count)
          expect(response).to have_http_status(:not_found)
        end
      end

      it 'cannot renew or exchange a pending recovery/popout grant after cutover' do
        grants = travel_to(cutoff - 1.second) do
          %w[recovery popout].index_with { |kind| http_session.handoff(kind: kind) }
        end
        old_proof = proof
        stub_epoch(cutoff)
        post_session('/proof', {}, old_proof)
        expect(response).to have_http_status(:not_found)
        cookies.delete(cookie_name)
        handoff_actions.each do |kind, action|
          post_session(action, { handoff_code: grants.fetch(kind), consume_intent: SecureRandom.hex(32) })
          expect(response).to have_http_status(:not_found)
        end
      end

      it 'rejects a bootstrap replay even after the old cookie has been removed' do
        intent = SecureRandom.hex(32)
        travel_to(cutoff - 1.second) { post_session('', { consume_intent: intent }) }
        expect(response).to have_http_status(:ok)
        expect(Toybaco::WidgetSessionRecord.last.id).to eq(row.id)
        stub_epoch(cutoff)
        cookies.delete(cookie_name)
        expect { post_session('', { consume_intent: intent }) }.not_to change(Toybaco::WidgetSessionRecord, :count)
        expect(response).to have_http_status(:not_found)
      end

      it 'replaces the retired cookie with a fresh anonymous visitor without a conflict or explicit reset', :aggregate_failures do
        message
        stub_epoch(cutoff)
        expect { post_session('', { consume_intent: SecureRandom.hex(32) }) }.to change(Toybaco::WidgetSessionRecord, :count).by(1)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include('issued' => true)
        fresh_proof = response.parsed_body.fetch('proof')
        fresh = Toybaco::WidgetSessionRecord.last
        expect(fresh).to be_current
        expect(fresh.contact_inbox_id).not_to eq(link.id)
        expect(fresh.contact_inbox.contact.attributes.values_at('email', 'identifier')).to eq([nil, nil])
        expect(row.reload.revoked_at).to be_present
        expect(cookies[cookie_name]).to start_with("#{fresh.id}.")
        get '/api/v1/widget/http_session', params: { website_token: widget.website_token },
                                           headers: headers.merge('X-Auth-Token' => fresh_proof)
        expect(response.parsed_body['persisted']).to be(true)
        expect_empty_visitor(response.parsed_body.fetch('proof'))
        expect(message.reload.conversation_id).to eq(conversation.id)
        expect(conversation.reload.contact_inbox_id).to eq(link.id)
      end

      it 'cannot access the retired history after automatic replacement even with a replayed cookie or recovery proof' do
        message
        old_proof = proof
        old_recovery = recovery
        stub_epoch(cutoff)
        post_session('', { consume_intent: SecureRandom.hex(32) })
        expect(response).to have_http_status(:ok)
        cookies[cookie_name] = cookie
        read_widget('messages', old_proof)
        expect(response).to have_http_status(:not_found)
        cookies.delete(cookie_name)
        read_widget('messages', old_recovery)
        expect(response).to have_http_status(:not_found)
        expect(message.reload.content).to eq('Pre-cutover private history')
      end

      it 'reconciles a lost replacement response without resuming the retired visitor or creating another one' do
        stub_epoch(cutoff)
        intent = SecureRandom.hex(32)
        post_session('', { consume_intent: intent })
        expect(response).to have_http_status(:ok)
        fresh = Toybaco::WidgetSessionRecord.last
        cookies[cookie_name] = cookie
        expect { post_session('', { consume_intent: intent }) }.not_to change(Toybaco::WidgetSessionRecord, :count)
        expect(response).to have_http_status(:ok)
        expect(cookies[cookie_name]).to start_with("#{fresh.id}.")
        expect_empty_visitor(response.parsed_body.fetch('proof'))
      end

      it 'does not retire a row on the basis of its id without a matching cookie secret' do
        stub_epoch(cutoff)
        cookies[cookie_name] = "#{row.id}.#{SecureRandom.hex(32)}"
        expect { post_session('', { consume_intent: SecureRandom.hex(32) }) }.not_to change(Toybaco::WidgetSessionRecord, :count)
        expect(response).to have_http_status(:conflict)
        expect(row.reload.revoked_at).to be_nil
      end

      it 'keeps a genuine conflict between two current visitors and does not replace the browser cookie' do
        stub_epoch(cutoff)
        row.update!(created_at: cutoff)
        grant = http_session.handoff
        cookies.delete(cookie_name)
        post_session('', { consume_intent: SecureRandom.hex(32) })
        expect(response).to have_http_status(:ok)
        current_cookie = cookies[cookie_name]
        expect do
          post_session('/consume', { handoff_code: grant, consume_intent: SecureRandom.hex(32) })
        end.not_to change(Toybaco::WidgetSessionRecord, :count)
        expect(response).to have_http_status(:conflict)
        expect(response.parsed_body['error']).to eq('widget_session_conflict')
        expect(cookies[cookie_name]).to eq(current_cookie)
        expect(row.reload.revoked_at).to be_nil
      end

      it 'keeps post-cutover HTTP and recovery sessions working' do
        message
        stub_epoch(cutoff)
        row.update!(created_at: cutoff + 1.second)
        [proof, recovery].each do |credential|
          read_widget('contact', credential)
          expect(response).to have_http_status(:ok)
          expect(response.parsed_body['id']).to eq(victim.id)
          read_widget('messages', credential)
          expect(response).to have_http_status(:ok)
          expect(response.body).to include(message.content)
        end
        expect(row.reload).to be_current
      end

      it 'accepts sessions created exactly at the cutover and preserves their existing history' do
        message
        stub_epoch(cutoff)
        row.update!(created_at: cutoff)
        expect { post_session('', { consume_intent: SecureRandom.hex(32) }) }.not_to change(Toybaco::WidgetSessionRecord, :count)
        expect(response).to have_http_status(:ok)
        expect(cookies[cookie_name]).to eq(cookie)
        expect(row.reload.revoked_at).to be_nil
        read_widget('contact', proof)
        expect(response.parsed_body['id']).to eq(victim.id)
        read_widget('messages', proof)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(message.content)
      end
    end
  end
end
