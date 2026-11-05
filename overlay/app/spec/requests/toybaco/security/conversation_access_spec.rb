# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Conversation authorization on auxiliary endpoints', type: :request do
  include_context 'without toybaco network connections'
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:headers) { { 'api_access_token' => agent.access_token.token } }

  def api(path)
    "/api/v1/accounts/#{account.id}/#{path}"
  end

  def join_inbox
    create(:inbox_member, inbox: inbox, user: agent)
  end

  describe 'Captain tasks' do
    {
      rewrite: Captain::RewriteService, summarize: Captain::SummaryService,
      reply_suggestion: Captain::ReplySuggestionService, label_suggestion: Captain::LabelSuggestionService,
      follow_up: Captain::FollowUpService
    }.each do |action, service|
      context "with #{action}" do
        before do
          allow(service).to receive(:new).and_return(instance_double(service, perform: { message: 'Synthetic answer' }))
        end

        it 'rejects an unrelated agent before any task service receives the conversation' do
          post api("captain/tasks/#{action}"), params: { conversation_display_id: conversation.display_id }, headers: headers, as: :json

          expect(response).to have_http_status(:unauthorized)
          expect(service).not_to have_received(:new)
          expect(response.parsed_body).to eq('error' => 'You are not authorized to do this action')
        end

        it 'allows an inbox member through the same policy as conversation show' do
          join_inbox
          post api("captain/tasks/#{action}"), params: { conversation_display_id: conversation.display_id }, headers: headers, as: :json

          expect(response).to have_http_status(:ok)
          expect(service).to have_received(:new)
          expect(response.parsed_body['message']).to eq('Synthetic answer')
        end
      end
    end

    it 'keeps conversation-free rewriting available' do
      service = instance_double(Captain::RewriteService, perform: { message: 'Synthetic rewrite' })
      allow(Captain::RewriteService).to receive(:new).and_return(service)
      post api('captain/tasks/rewrite'), params: { content: 'Synthetic text', operation: 'improve' }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(service).to have_received(:perform)
    end

    it 'does not resolve another account conversation by its display id' do
      other = create(:conversation, display_id: 987_654)
      post api('captain/tasks/summarize'), params: { conversation_display_id: other.display_id }, headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'conversation direct uploads' do
    before { account.enable_features!('api_and_webhooks') }

    around do |example|
      previous = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = previous
    end

    def reserve_upload(auth_headers = headers)
      post api("conversations/#{conversation.display_id}/direct_uploads"),
           params: { blob: { filename: 'report.txt', content_type: 'text/plain', byte_size: 4, checksum: Digest::MD5.base64digest('text') } },
           headers: auth_headers, as: :json
    end

    it 'does not reserve a blob for an agent without conversation access' do
      conversation
      expect { reserve_upload }.not_to change(ActiveStorage::Blob, :count)
      expect(response).to have_http_status(:unauthorized)
    end

    it 'allows a member using an API token' do
      join_inbox
      expect { reserve_upload }.to change(ActiveStorage::Blob, :count).by(1)
      expect(response).to have_http_status(:ok)
    end

    context 'with a dashboard browser session' do
      let(:browser_headers) do
        { 'X-Toybaco-Browser' => '1', 'Origin' => 'https://chatwoot.test', 'Sec-Fetch-Site' => 'same-origin' }
      end

      before do
        host! 'chatwoot.test'
        https!
        join_inbox
        browser_login
      end

      def browser_csrf
        get '/toybaco/browser-session', headers: browser_headers
        expect(response).to have_http_status(:ok)
        response.parsed_body.fetch('csrf_token')
      end

      def browser_login
        post '/auth/sign_in',
             params: { email: agent.email, password: 'Password1!' },
             headers: browser_headers.merge('X-CSRF-Token' => browser_csrf), as: :json
        expect_browser_session
      end

      def expect_browser_session
        expect(response).to have_http_status(:ok)
        expect(cookies['cw_d_session_info']).to be_present
        credential = Array(response.headers['Set-Cookie']).find { |entry| entry.start_with?('cw_d_session_info=') }
        expect(credential).to match(/; httponly/i)
        expect(response.headers.values_at('access-token', 'client', 'uid')).to all(be_nil)
      end

      it 'allows a member using the session cookie and a bound CSRF token' do
        csrf_headers = browser_headers.merge('X-CSRF-Token' => browser_csrf)

        expect { reserve_upload(csrf_headers) }.to change(ActiveStorage::Blob, :count).by(1)

        expect(response).to have_http_status(:ok)
        expect(response.headers['access-token']).to be_nil
      end

      it 'rejects the same session without a CSRF token before reserving a blob' do
        conversation

        expect { reserve_upload(browser_headers) }.not_to change(ActiveStorage::Blob, :count)

        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body).to eq('error' => 'csrf_verification_failed')
      end
    end

    it 'retains administrator access without inbox membership' do
      admin = create(:user, account: account, role: :administrator)
      reserve_upload('api_access_token' => admin.access_token.token)
      expect(response).to have_http_status(:ok)
    end

    it 'retains the conversation policy team access rule' do
      team = create(:team, account: account)
      create(:team_member, team: team, user: agent)
      conversation.update!(team: team)
      reserve_upload
      expect(response).to have_http_status(:ok)
    end

    it 'returns 404 and does not create a blob for a missing conversation' do
      conversation.destroy!
      expect { reserve_upload }.not_to change(ActiveStorage::Blob, :count)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'Linear conversation operations' do
    let(:processor) { instance_double(Integrations::Linear::ProcessorService) }

    before do
      allow(Integrations::Linear::ProcessorService).to receive(:new).and_return(processor)
      allow(Linear::ActivityMessageService).to receive(:new).and_return(instance_double(Linear::ActivityMessageService, perform: nil))
      allow(processor).to receive(:linked_issues).and_return(data: [{ 'id' => 'own-link', 'issue' => { 'identifier' => 'SYN-1' } }])
    end

    { create_issue: :post, link_issue: :post, unlink_issue: :post, linked_issues: :get }.each do |action, verb|
      context "with #{action}" do
        before { allow(processor).to receive(action).and_return(data: { identifier: 'SYN-1' }) }

        it 'rejects an unrelated agent before reading or changing Linear or creating activity' do
          conversation
          expect do
            public_send(verb, api("integrations/linear/#{action}"),
                        params: { conversation_id: conversation.display_id, issue_id: 'SYN-1' }, headers: headers, as: :json)
          end.not_to change(Message, :count)

          expect(response).to have_http_status(:unauthorized)
          expect(Integrations::Linear::ProcessorService).not_to have_received(:new)
          expect(Linear::ActivityMessageService).not_to have_received(:new)
        end

        it 'allows a member of the conversation inbox' do
          join_inbox
          public_send(verb, api("integrations/linear/#{action}"),
                      params: { conversation_id: conversation.display_id, issue_id: 'SYN-1', link_id: 'own-link' }, headers: headers, as: :json)

          expect(response).to have_http_status(:ok)
          expect(processor).to have_received(action)
        end
      end
    end

    it 'rejects a restricted conversation link substituted alongside an accessible conversation' do
      join_inbox
      restricted = create(:conversation, account: account, inbox: create(:inbox, account: account))
      own_url = "#{ENV.fetch('FRONTEND_URL', nil)}/app/accounts/#{account.id}/conversations/#{conversation.display_id}"
      restricted_url = "#{ENV.fetch('FRONTEND_URL', nil)}/app/accounts/#{account.id}/conversations/#{restricted.display_id}"
      allow(processor).to receive(:linked_issues).with(own_url).and_return(data: [{ 'id' => 'own-link', 'issue' => { 'identifier' => 'OWN-1' } }])
      allow(processor).to receive(:linked_issues).with(restricted_url).and_return(data: [{ 'id' => 'restricted-link',
                                                                                           'issue' => { 'identifier' => 'PRIVATE-1' } }])
      allow(processor).to receive(:unlink_issue).and_return(data: { link_id: 'restricted-link' })

      expect do
        post api('integrations/linear/unlink_issue'),
             params: { conversation_id: conversation.display_id, link_id: 'restricted-link', issue_id: 'FORGED-1' }, headers: headers, as: :json
      end.not_to change(Message, :count)

      expect(response).to have_http_status(:not_found)
      expect(processor).to have_received(:linked_issues).with(own_url)
      expect(processor).not_to have_received(:linked_issues).with(restricted_url)
      expect(processor).not_to have_received(:unlink_issue)
      expect(Linear::ActivityMessageService).not_to have_received(:new)
    end

    it 'uses the resolved link for deletion and activity, ignoring a forged issue id' do
      join_inbox
      allow(processor).to receive(:unlink_issue).with('own-link').and_return(data: { link_id: 'own-link' })
      post api('integrations/linear/unlink_issue'),
           params: { conversation_id: conversation.display_id, link_id: 'own-link', issue_id: 'FORGED-1' }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(processor).to have_received(:unlink_issue).with('own-link')
      expect(Linear::ActivityMessageService).to have_received(:new).with(
        conversation: conversation, action_type: :issue_unlinked, issue_data: { id: 'SYN-1' }, user: agent
      )
    end

    it 'does not delete or record activity if the scoped link lookup fails' do
      join_inbox
      allow(processor).to receive(:linked_issues).and_return(error: 'Synthetic lookup failure')
      allow(processor).to receive(:unlink_issue)
      post api('integrations/linear/unlink_issue'),
           params: { conversation_id: conversation.display_id, link_id: 'own-link' }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(processor).not_to have_received(:unlink_issue)
      expect(Linear::ActivityMessageService).not_to have_received(:new)
    end
  end
end
