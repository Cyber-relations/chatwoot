# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Toybaco AI usage', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending) }
  let(:message) { create(:message, account: account, inbox: inbox, conversation: conversation) }
  let(:bot) { create(:agent_bot) }
  let(:headers) { { 'api_access_token' => bot.access_token.token } }
  let(:params) { { account_id: account.id, conversation_id: conversation.display_id, message_id: message.id, action_type: 'reserve' } }

  before do
    contract = Toybaco::Entitlements.snapshot_for(Toybaco::PlanCatalog.default.sale('pro', 'month'), cycle: 'month')
    account.update!(internal_attributes: { 'toybaco_contract' => contract })
    create(:agent_bot_inbox, agent_bot: bot, inbox: inbox)
  end

  it '利用枠を予約・消費し、受信メッセージの再送を重複処理しない' do
    post '/toybaco/ai_usage', params: params, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    token = response.parsed_body.fetch('token')
    expect(response.parsed_body).to include('result' => 'reserved', 'used' => 0, 'reserved' => 1)
    post '/toybaco/ai_usage', params: params.merge(action_type: 'consumed', token: token), headers: headers, as: :json
    expect(response.parsed_body).to include('result' => 'consumed', 'used' => 1, 'reserved' => 0)
    post '/toybaco/ai_usage', params: params, headers: headers, as: :json
    expect(response.parsed_body['result']).to eq('duplicate')
    expect(message.reload.content_attributes.dig('toybaco_ai_usage', 'state')).to eq('consumed')
  end

  it 'botが所属しないテナントと、同テナント内の未割当受信箱を拒否する' do
    other = create(:account)
    post '/toybaco/ai_usage', params: params.merge(account_id: other.id), headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
    another_inbox = create(:inbox, account: account)
    another_conversation = create(:conversation, account: account, inbox: another_inbox, status: :pending)
    post '/toybaco/ai_usage', params: params.merge(conversation_id: another_conversation.display_id), headers: headers, as: :json
    expect(response).to have_http_status(:not_found)
    expect(account.reload.internal_attributes).not_to have_key('toybaco_ai_usage')
  end

  it '人間のAPI tokenでは枠を変更できない' do
    user = create(:user, account: account)
    post '/toybaco/ai_usage', params: params, headers: { 'api_access_token' => user.access_token.token }, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'ログイン会員は自分の利用状況だけを読み、cookieで枠を書き換えない' do
    user = create(:user, account: account)
    reader = instance_double(Toybaco::Oidc::SessionReader, user: user)
    allow(Toybaco::Oidc::SessionReader).to receive(:new).and_return(reader)
    get '/toybaco/ai_usage', params: { account_id: account.id }
    expect(response.parsed_body).to include('enabled' => true, 'limit' => 500, 'used' => 0)
    expect(response.headers['Cache-Control']).to eq('no-store')
    post '/toybaco/ai_usage', params: params, as: :json
    expect(response).to have_http_status(:unauthorized)
    get '/toybaco/ai_usage', params: { account_id: create(:account).id }
    expect(response).to have_http_status(:unauthorized)
  end

  it '存在しない受信メッセージと内部メモを生成対象にしない' do
    post '/toybaco/ai_usage', params: params.merge(message_id: Message.maximum(:id) + 1), headers: headers, as: :json
    expect(response).to have_http_status(:not_found)
    message.update!(private: true)
    post '/toybaco/ai_usage', params: params, headers: headers, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it '無効化したbotは利用枠を変更できない' do
    bot.agent_bot_inboxes.each { |assignment| assignment.update!(status: :inactive) }
    post '/toybaco/ai_usage', params: params, headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
  end
end
