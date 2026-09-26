# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Toybaco checkout terms', type: :request do
  let(:terms) { Toybaco::Checkout::Catalog.sale('pro', 'year') }
  let(:current) { { plan: 'pro', cycle: 'year', version: terms['plan_version'] } }
  let(:legal) { Toybaco::LegalTerms }

  it '古い表示・版のない・現在の版のどのリンクからも決済を開始せず同意欄のある現在条件を提示する' do
    expect(Toybaco::Checkout).not_to receive(:start!)
    [nil, 'old-version', terms['plan_version']].each do |version|
      get '/toybaco/checkout', params: { plan: 'pro', cycle: 'year', version: version }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('321,840円', '月2,000回まで（返信・投稿で共通）', terms['plan_version'], 'この内容で決済に進む',
                                       '<input type="checkbox" name="accept_terms" value="1" required>',
                                       legal::TERMS_URL, legal::TOKUSHOHO_URL, legal::PRIVACY_URL)
      expect(response.headers['Cache-Control']).to eq('no-store')
    end
  end

  it '同意欄にチェックのない送信は422で確認画面へ戻し決済を開始しない' do
    expect(Toybaco::Checkout).not_to receive(:start!)
    [{}, { accept_terms: '0' }].each do |consent|
      post '/toybaco/checkout', params: current.merge(consent)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include('利用規約などへの同意が必要です', 'name="accept_terms"')
    end
  end

  it '古い版や他サイトからの送信は同意があっても現在の条件を再提示する' do
    expect(Toybaco::Checkout).not_to receive(:start!)
    post '/toybaco/checkout', params: current.merge(version: 'old-version', accept_terms: '1')
    expect(response).to have_http_status(:ok)
    post '/toybaco/checkout', params: current.merge(accept_terms: '1'), headers: { 'Sec-Fetch-Site' => 'cross-site' }
    expect(response).to have_http_status(:ok)
    post '/toybaco/checkout', params: current.merge(accept_terms: '1'), headers: { 'Origin' => 'https://elsewhere.example' }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('name="accept_terms"')
  end

  it '現在の版に同意した送信だけが規約の版と同意日時を付けて決済へ渡す' do
    started = Time.now.utc.change(usec: 0)
    expect(Toybaco::Checkout).to receive(:start!) do |**input|
      expect(input.except(:consent)).to eq(current)
      expect(input[:consent]['terms_version']).to eq(legal::VERSION)
      expect(Time.iso8601(input[:consent]['accepted_at'])).to be_between(started, Time.now.utc)
      { 'url' => 'https://checkout.stripe.com/c/pay/fixture' }
    end
    post '/toybaco/checkout', params: current.merge(accept_terms: '1'),
                              headers: { 'Origin' => 'http://www.example.com', 'Sec-Fetch-Site' => 'same-origin' }
    expect(response).to redirect_to('https://checkout.stripe.com/c/pay/fixture')
    expect(response).to have_http_status(:see_other)
  end

  it '期間末に無料プランへ移る版だけが無料プランと更新猶予の条件を表示する' do
    get '/toybaco/checkout', params: { plan: 'standard', cycle: 'month' }
    expect(response.body).to include('19,800円', '月500回まで（返信・投稿で共通）', '現在の契約期間末に無料プランへ移ります',
                                     '7日間の猶予の後、無料プラン相当へ移ります')
    allow(Toybaco::Checkout::Catalog).to receive(:sale).and_return(Toybaco::PlanCatalog.default.definition('pro', '2026-09-06.1'))
    get '/toybaco/checkout', params: { plan: 'pro', cycle: 'year' }
    expect(response.body).to include('「ご契約内容」からいつでも手続きできます')
    expect(response.body).not_to include('無料プラン')
  end

  it '未知のプランを現行プランに読み替えない' do
    expect(Toybaco::Checkout).not_to receive(:start!)
    get '/toybaco/checkout', params: { plan: 'retired-unknown', cycle: 'month' }
    expect(response).to have_http_status(:bad_request)
  end
end
