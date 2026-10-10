# frozen_string_literal: true

require 'rails_helper'

# 段 1a(2026-10-06 owner 裁定): 初回ツアーは 店舗情報 → 窓口 → 受信 → 返信 → この窓口の AI返信を決める の順。
# 段 decide は、返信案だけ・自動の記録、窓口の自動応答の登録、「あとで設定する」のどれかで済む。
RSpec.describe 'Toybaco growth onboarding', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }

  before do
    terms = Toybaco::PlanCatalog.default.definition('free', '2026-09-25.1')
    Toybaco::Entitlements.apply!(account, Toybaco::Entitlements.snapshot_for(terms, cycle: nil))
    allow(Toybaco::Oidc::SessionReader).to receive(:new).and_return(instance_double(Toybaco::Oidc::SessionReader, user: user))
  end

  def guide
    get '/toybaco/growth/onboarding', params: { account_id: account.id }
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def choose(preference)
    put '/toybaco/growth/onboarding', params: { account_id: account.id, preference: preference },
                                      headers: { 'Origin' => 'http://www.example.com' }, as: :json
  end

  it '問い合わせの段は店舗情報から始まり、窓口・受信・返信のあとに AI返信を決める段がある' do
    choose(purpose: 'inbox')
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.values_at('phase', 'steps')).to eq(['facts', %w[purpose facts connect receive reply decide complete]])
    expect(guide['preference']).not_to have_key('ai_reply_choice')
  end

  it 'AI返信の使い方は auto と draft_only だけを保存し、ほかの値は 422 にする' do
    ['draft', 'off', '', nil, ['draft_only']].each do |value|
      choose(purpose: 'inbox', ai_reply_choice: value)
      expect(response).to have_http_status(:unprocessable_entity), value.inspect
    end
    expect(guide['preference']).to eq({})
    choose(purpose: 'inbox', ai_reply_choice: 'draft_only')
    expect(response).to have_http_status(:ok)
    expect(guide.dig('preference', 'ai_reply_choice')).to eq('draft_only')
  end

  it '管理者以外が AI返信の使い方を送ると 403 で何も保存せず、「あとで設定する」は誰でもできる' do
    choose(purpose: 'inbox')
    account.account_users.find_by!(user: user).update!(role: :agent)
    saved = guide['preference']
    choose(ai_reply_choice: 'draft_only', dismissed: true)
    expect(response).to have_http_status(:forbidden)
    expect(guide['preference']).to eq(saved)
    expect(saved).not_to include('ai_reply_choice', 'dismissed')
    choose(skipped: ['decide'])
    expect(response).to have_http_status(:ok)
    expect(guide.dig('preference', 'skipped')).to eq(['decide'])
  end

  it '店舗情報の画面の「AI はこう理解しています」は、保存した店舗情報の 7 項目のうち値のある項目を数える' do
    Toybaco::Growth::StoreFacts.new(account).save!({ 'name' => 'テスト店舗', 'booking' => 'お電話で' }, user: user)
    expect(guide.dig('facts', 'understanding')).to eq(
      'filled' => %w[name booking], 'missing' => %w[hours address phone services cancellation], 'total' => 7
    )
  end

  it '業種はパックの id だけを管理者が選べ、店舗情報の fields と確認は変えない' do
    put '/toybaco/growth/facts', params: { account_id: account.id, industry: 'unknown' },
                                 headers: { 'Origin' => 'http://www.example.com' }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    put '/toybaco/growth/facts', params: { account_id: account.id, industry: 'beauty' },
                                 headers: { 'Origin' => 'http://www.example.com' }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['facts'].values_at('industry', 'industry_fixed', 'confirmed')).to eq(['beauty', false, false])
    expect(response.parsed_body.dig('facts', 'questions').first).to eq('question' => '当日予約はできますか', 'field' => 'booking')
  end

  it '管理者以外が業種を送ると 403 で、何も保存しない' do
    account.account_users.find_by!(user: user).update!(role: :agent)
    put '/toybaco/growth/facts', params: { account_id: account.id, industry: 'beauty' },
                                 headers: { 'Origin' => 'http://www.example.com' }, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(guide.dig('facts', 'industry')).to be_nil
  end

  it '案内する窓口の AI返信を決めるまで decide の段にとどまり、返信案だけを選ぶと完了する' do
    inbox = create(:inbox, account: account)
    Toybaco::Growth::StoreFacts.new(account).save!({ 'name' => 'テスト店舗' }, user: user)
    choose(purpose: 'inbox', skipped: ['receive'])
    expect(response.parsed_body.values_at('phase', 'inbox_id')).to eq(['decide', inbox.id])
    choose(ai_reply_choice: 'draft_only')
    expect(response.parsed_body.values_at('phase', 'replied')).to eq(['complete', false])
  end
end
