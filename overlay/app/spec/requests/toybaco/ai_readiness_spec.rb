# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Toybaco AI connection settings', type: :request do
  let(:account) { create(:account, internal_attributes: { 'toybaco_ai_reply_mode' => 'draft' }) }
  let(:user) { create(:user, account: account) }

  before do
    reader = instance_double(Toybaco::Oidc::SessionReader, user: user)
    allow(Toybaco::Oidc::SessionReader).to receive(:new).and_return(reader)
  end

  def read_connection(id = account.id, headers = {})
    get '/toybaco/ai_readiness', params: { account_id: id }, headers: headers
  end

  def assign_bot(owner: account, status: :active, url: 'https://worker.example.invalid/webhook')
    bot = create(:agent_bot, account: owner, outgoing_url: url)
    inbox = create(:inbox, account: account)
    create(:agent_bot_inbox, agent_bot: bot, inbox: inbox, status: status)
  end

  it 'Botのない店舗を未接続と返し、保存済みモードや契約を変更しない' do
    before_attributes = account.internal_attributes.deep_dup
    read_connection
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(
      'connection' => 'unconnected', 'configured_inboxes' => 0, 'total_inboxes' => 0, 'live_verification' => 'unverified'
    )
    expect(response.headers['Cache-Control']).to eq('no-store')
    expect(account.reload.internal_attributes).to eq(before_attributes)
  end

  it '自店舗所有と正規global Botのactive設定だけを集計し、秘密情報を返さない' do
    assign_bot
    assign_bot(owner: nil)
    assign_bot(status: :inactive)
    assign_bot(url: '   ')
    elsewhere = create(:account)
    other_bot = create(:agent_bot, account: elsewhere, outgoing_url: 'https://elsewhere.example.invalid')
    create(:agent_bot_inbox, agent_bot: other_bot, inbox: create(:inbox, account: elsewhere))

    read_connection
    expect(response.parsed_body).to eq(
      'connection' => 'configured', 'configured_inboxes' => 2, 'total_inboxes' => 4, 'live_verification' => 'unverified'
    )
    expect(response.body).not_to match(/token|secret|outgoing_url|worker\.example|elsewhere|bot_id/)
  end

  it 'Botの無効化を次回確認へ反映し、設定ありを稼働確認済みと扱わない' do
    assignment = assign_bot
    read_connection
    expect(response.parsed_body).to include('connection' => 'configured', 'live_verification' => 'unverified')
    assignment.update!(status: :inactive)
    read_connection
    expect(response.parsed_body).to include(
      'connection' => 'unconnected', 'configured_inboxes' => 0, 'live_verification' => 'unverified'
    )
  end

  it '別店舗所有Botへの不整合な割当を接続済みとも未接続とも断定しない' do
    assign_bot(owner: create(:account))
    read_connection
    expect(response.parsed_body).to eq(
      'connection' => 'unknown', 'configured_inboxes' => 0, 'total_inboxes' => 1, 'live_verification' => 'unverified'
    )
  end

  it '非所属店舗・不正ID・未ログインを拒否し、bot tokenで会員認証を代用しない' do
    read_connection(create(:account).id)
    expect(response).to have_http_status(:unauthorized)
    read_connection('../1')
    expect(response).to have_http_status(:bad_request)
    bot = assign_bot.agent_bot
    allow(Toybaco::Oidc::SessionReader).to receive(:new).and_return(instance_double(Toybaco::Oidc::SessionReader, user: nil))
    read_connection(account.id, { 'api_access_token' => bot.access_token.token })
    expect(response).to have_http_status(:unauthorized)
    expect(response.body).to be_blank
  end

  it 'DB障害は確認不能を返し、未接続や内部エラー詳細として表示しない' do
    allow(Toybaco::AiReadiness).to receive(:for_account).and_raise(ActiveRecord::StatementInvalid, 'private connection details')
    read_connection
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to eq('connection' => 'unknown')
    expect(response.body).not_to include('private connection details')
  end
end
