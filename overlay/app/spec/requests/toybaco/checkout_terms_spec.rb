# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Toybaco checkout terms', type: :request do
  let(:terms) { Toybaco::Checkout::Catalog.sale('pro', 'year') }

  it '古い表示または版のない申込リンクから決済を開始せず現在条件を提示する' do
    expect(Toybaco::Checkout).not_to receive(:start!)
    [nil, 'old-version'].each do |version|
      get '/toybaco/checkout', params: { plan: 'pro', cycle: 'year', version: version }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('483,840円', '月500回まで', terms['plan_version'], 'この内容で決済に進む')
      expect(response.headers['Cache-Control']).to eq('no-store')
    end
  end

  it '現在の版に同意したリクエストのみその版を決済へ渡す' do
    expect(Toybaco::Checkout).to receive(:start!).with(plan: 'pro', cycle: 'year', version: terms['plan_version'])
                                                 .and_return('url' => 'https://checkout.stripe.com/c/pay/fixture')
    post '/toybaco/checkout', params: { plan: 'pro', cycle: 'year', version: terms['plan_version'] }
    expect(response).to redirect_to('https://checkout.stripe.com/c/pay/fixture')
    expect(response).to have_http_status(:see_other)
  end

  it '未知のプランを現行プランに読み替えない' do
    expect(Toybaco::Checkout).not_to receive(:start!)
    get '/toybaco/checkout', params: { plan: 'retired-unknown', cycle: 'month' }
    expect(response).to have_http_status(:bad_request)
  end
end
