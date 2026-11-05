# frozen_string_literal: true

require 'rails_helper'

# staging の DAST(2026-11-03)で GET reports・reports/summary・reports/conversations が 500 になった入力。type の欠け
# (nil の to_sym の NoMethodError)と知らない type(builder の scope が nil)、since・until の形の誤り(Date::Error)と範囲外
# (PG::DatetimeFieldOverflow)。builder に渡す前に照らして 422 を返す。正しい組み合わせの応答は今のまま。
RSpec.describe 'Toybaco reports params guard', type: :request do
  let!(:account) { create(:account) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:inbox) { create(:inbox, account: account) }
  let(:headers) { { 'api_access_token' => admin.access_token.token } }
  let(:base) { "/api/v2/accounts/#{account.id}/reports" }
  let(:since) { Time.utc(2026, 10, 1).to_i.to_s }
  let(:upto) { Time.utc(2026, 10, 8).to_i.to_s }
  let(:guard) { Toybaco::Security::ApiInputGuard::Reports }
  # PostgreSQL の timestamp に入らない UNIX 秒(DAST の範囲外の日時と同じ形)。
  let(:overflow) { '99999999999999' }

  before do
    travel_to(Time.utc(2026, 10, 3, 12)) { create(:conversation, account: account, inbox: inbox) }
  end

  def report(path, params)
    get "#{base}#{path}", params: params, headers: headers
  end

  describe 'GET reports' do
    let(:valid) { { metric: 'conversations_count', type: 'account', since: since, until: upto } }

    it '正しい組み合わせは今の時系列を返す(type が空の文字列は account と同じ)' do
      report('', valid)
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body.length).to eq(7)
      expect(body.select { |entry| entry['value'].positive? }).to eq([{ 'value' => 1, 'timestamp' => Time.utc(2026, 10, 3).to_i }])

      report('', valid.merge(type: ''))
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(body)
    end

    it 'since だけ・until だけ・期間なしの時も今のまま返す' do
      [valid.except(:until), valid.except(:since), valid.except(:since, :until)].each do |params|
        report('', params)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to be_an(Array)
      end
    end

    it 'type が無い・知らない・文字列でない時は 422' do
      [valid.except(:type), valid.merge(type: 'dast'), valid.merge(type: ['account'])].each do |params|
        report('', params)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq('error' => guard::TYPE_MESSAGE)
      end
    end

    it 'since・until が UNIX 秒でない時は 422' do
      [valid.merge(since: 'dast'), valid.merge(until: 'dast'), valid.merge(since: [since])].each do |params|
        report('', params)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq('error' => guard::FORMAT_MESSAGE)
      end
    end

    it 'since・until が PostgreSQL の timestamp に入らない時は 422' do
      [valid.merge(until: overflow), valid.merge(since: "-#{overflow}")].each do |params|
        report('', params)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq('error' => guard::RANGE_MESSAGE)
      end
    end

    it '範囲の端(0001-01-01T00:00:00Z と 9999-12-31T23:59:59Z)は通し、その外は 422' do
      first = -62_135_596_800
      last = 253_402_300_799
      expect([first, last].map { |epoch| Time.at(epoch).utc.iso8601 }).to eq(%w[0001-01-01T00:00:00Z 9999-12-31T23:59:59Z])
      report('', valid.merge(metric: 'dast', since: first.to_s, until: last.to_s))
      expect(response).to have_http_status(:ok)
      [{ since: (first - 1).to_s }, { until: (last + 1).to_s }].each do |edge|
        report('', valid.merge(metric: 'dast', **edge))
        expect(response).to have_http_status(:unprocessable_entity)
      end
      expect(guard::EPOCH_RANGE).to eq(first..last)
    end

    it '照らすのは認可の後(report を見られない agent は今のまま 401)' do
      agent = create(:user, account: account, role: :agent)
      get base, params: valid.except(:type), headers: { 'api_access_token' => agent.access_token.token }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'GET reports/summary' do
    let(:valid) { { type: 'account', since: since, until: upto } }

    it '正しい組み合わせは今の集計と前の期間を返す(type が空の文字列は account と同じ)' do
      report('/summary', valid)
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body['conversations_count']).to eq(1)
      expect(body.dig('previous', 'conversations_count')).to eq(0)

      report('/summary', valid.merge(type: ''))
      expect(response.parsed_body).to eq(body)
    end

    it 'type が無い・知らない時は 422' do
      [valid.except(:type), valid.merge(type: 'dast')].each do |params|
        report('/summary', params)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq('error' => guard::TYPE_MESSAGE)
      end
    end

    it 'since・until の形の誤りと範囲外、前の期間が範囲外になる時は 422' do
      { valid.merge(since: 'dast') => :FORMAT_MESSAGE, valid.merge(until: overflow) => :RANGE_MESSAGE,
        valid.merge(since: '0', until: '253402300799') => :RANGE_MESSAGE }.each do |params, message|
        report('/summary', params)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq('error' => guard.const_get(message))
      end
    end
  end

  describe 'GET reports/conversations' do
    it '正しい type は今の数を返し、type が空なら今のまま中身なしの 422' do
      report('/conversations', type: 'account')
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.keys).to match_array(%w[open unattended unassigned pending])
      expect(response.parsed_body.values_at('open', 'pending')).to eq([1, 0])

      report('/conversations', type: 'agent')
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.pluck('id')).to eq([admin.id])

      report('/conversations', {})
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to be_empty
    end

    it '知らない type・文字列でない type は 422' do
      [{ type: 'dast' }, { type: ['account'] }].each do |params|
        report('/conversations', params)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq('error' => guard::TYPE_MESSAGE)
      end
    end
  end
end
