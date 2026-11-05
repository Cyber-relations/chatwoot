# frozen_string_literal: true

require 'rails_helper'

# 第 1 回(reports_spec)の残り: reports の bot_summary・CSV の各 action・conversation_traffic、summary_reports、時系列と
# reports/conversations の id・page・timezone_offset。上流が例外にする入力は 422、上流が型を変えて受ける入力と正しい
# 組み合わせは今のまま。live_reports は上流が 4xx・200 で受けるので照らさない(今の応答を固定する)。
RSpec.describe 'Toybaco reports params guard (round 2)', type: :request do
  let!(:account) { create(:account) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:team) { create(:team, account: account) }
  let(:headers) { { 'api_access_token' => admin.access_token.token } }
  let(:reports) { "/api/v2/accounts/#{account.id}/reports" }
  let(:summary_reports) { "/api/v2/accounts/#{account.id}/summary_reports" }
  let(:live_reports) { "/api/v2/accounts/#{account.id}/live_reports" }
  let(:since) { Time.utc(2026, 10, 1).to_i.to_s }
  let(:upto) { Time.utc(2026, 10, 8).to_i.to_s }
  let(:overflow) { '99999999999999' }
  let(:guard) { Toybaco::Security::ApiInputGuard::Reports }

  before do
    create(:label, account: account, title: 'dast-label')
    travel_to(Time.utc(2026, 10, 3, 12)) { create(:conversation, account: account, inbox: inbox) }
  end

  def report(path, params)
    get path, params: params, headers: headers
  end

  def expect_error(message_name)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to eq('error' => guard.const_get(message_name))
  end

  describe 'GET reports/bot_summary' do
    let(:valid) { { type: 'account', since: since, until: upto } }

    it '正しい組み合わせは今の集計を返し、type の欠け・形の誤りは 422' do
      report("#{reports}/bot_summary", valid)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.keys).to match_array(%w[bot_resolutions_count bot_handoffs_count previous])

      { valid.except(:type) => :TYPE_MESSAGE, valid.merge(since: 'dast') => :FORMAT_MESSAGE,
        valid.merge(until: overflow) => :RANGE_MESSAGE }.each do |params, message|
        report("#{reports}/bot_summary", params)
        expect_error(message)
      end
    end
  end

  describe 'CSV の reports' do
    csv_actions = %i[agents inboxes labels teams conversations_summary]

    it '照らす CSV の action の名簿は guard と同じ' do
      expect(guard::CSV_ACTIONS).to eq(csv_actions)
    end

    csv_actions.each do |action|
      it "#{action} は正しい期間で今の CSV を返し、since・until の誤りは 422" do
        report("#{reports}/#{action}", since: since, until: upto)
        expect(response).to have_http_status(:ok)
        expect(response.headers['Content-Type']).to include('text/csv')

        { { since: 'dast', until: upto } => :FORMAT_MESSAGE, { since: [since], until: upto } => :FORMAT_MESSAGE,
          { since: since, until: overflow } => :RANGE_MESSAGE }.each do |params, message|
          report("#{reports}/#{action}", params)
          expect_error(message)
        end
      end
    end

    it 'conversation_traffic は timezone_offset がある時は今の CSV を返し、欠け・配列・範囲外の days_before は 422' do
      report("#{reports}/conversation_traffic", timezone_offset: '9', days_before: '6')
      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Type']).to include('text/csv')
      report("#{reports}/conversation_traffic", timezone_offset: '99')
      expect(response).to have_http_status(:ok)

      { {} => :TIMEZONE_MESSAGE, { timezone_offset: ['9'] } => :TIMEZONE_MESSAGE,
        { timezone_offset: '9', days_before: ['1'] } => :DAYS_MESSAGE,
        { timezone_offset: '9', days_before: '99999999999' } => :DAYS_MESSAGE }.each do |params, message|
        report("#{reports}/conversation_traffic", params)
        expect_error(message)
      end
    end
  end

  describe '時系列と reports/conversations の id・page・timezone_offset' do
    let(:timeseries) { { metric: 'conversations_count', type: 'account', since: since, until: upto } }

    it '配列の timezone_offset、account 以外の type での配列の id は 422' do
      report(reports, timeseries.merge(timezone_offset: ['9']))
      expect_error(:TIMEZONE_MESSAGE)
      report(reports, timeseries.merge(type: 'inbox', id: [inbox.id.to_s]))
      expect_error(:ID_MESSAGE)
      report("#{reports}/summary", timeseries.except(:metric).merge(type: 'inbox', id: [inbox.id.to_s]))
      expect_error(:ID_MESSAGE)
    end

    it '上流が受ける形は今のまま(account の配列の id、summary の配列の timezone_offset、Hash の id の 404)' do
      report(reports, timeseries.merge(id: [inbox.id.to_s]))
      expect(response).to have_http_status(:ok)
      report("#{reports}/summary", timeseries.except(:metric).merge(timezone_offset: ['9']))
      expect(response).to have_http_status(:ok)
      report("#{reports}/summary", timeseries.except(:metric).merge(type: 'inbox', id: { dast: '1' }))
      expect(response).to have_http_status(:not_found)
      report(reports, timeseries.merge(type: 'inbox', id: inbox.id.to_s, timezone_offset: '9'))
      expect(response).to have_http_status(:ok)
    end

    it 'reports/conversations の配列の page と、OFFSET が bigint を超える page は 422(正しい page は今のまま)' do
      report("#{reports}/conversations", type: 'agent', page: '2')
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq([])
      [['1'], '99999999999999999999'].each do |page|
        report("#{reports}/conversations", type: 'agent', page: page)
        expect_error(:PAGE_MESSAGE)
      end
    end
  end

  describe 'summary_reports' do
    it '各 action は正しい期間で今の集計を返し、since・until の形の誤りと範囲外は 422' do
      %i[agent team inbox label channel].each do |action|
        report("#{summary_reports}/#{action}", since: since, until: upto)
        expect(response).to have_http_status(:ok)

        { { since: 'dast', until: upto } => :FORMAT_MESSAGE, { since: since, until: 'dast' } => :FORMAT_MESSAGE,
          { since: since, until: overflow } => :RANGE_MESSAGE }.each do |params, message|
          report("#{summary_reports}/#{action}", params)
          expect_error(message)
        end
      end
    end

    it '上流の permit が落とす配列の since は今のまま(期間なしとして読む)' do
      report("#{summary_reports}/agent", since: [since], until: upto)
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'live_reports(照らさない。上流の応答のまま)' do
    it '配列の team_id は 200、配列の group_by は上流の 422、知らない team_id は 404' do
      report("#{live_reports}/conversation_metrics", team_id: [team.id.to_s])
      expect(response).to have_http_status(:ok)
      report("#{live_reports}/grouped_conversation_metrics", group_by: ['team_id'])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq('error' => 'invalid group_by')
      report("#{live_reports}/conversation_metrics", team_id: 'dast')
      expect(response).to have_http_status(:not_found)
    end
  end
end
