# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Toybaco 無料登録の hCaptcha', type: :request do
  let(:guard_message) { '「私は人間です」の確認にチェックを入れてから送信してください。' }
  let(:missing_token_message) do
    '「私は人間です」の確認にチェックを入れてから送信してください。確認欄が表示されない場合はページを再読み込みしてください。'
  end
  let(:verification_failed_message) { '確認に失敗しました。もう一度お試しください。' }
  let(:form) do
    { account_name: 'テスト店舗', user_full_name: 'テスト利用者', email: "free-#{SecureRandom.hex(8)}@example.com",
      password: 'Fixture-password!483', accept_terms: '1' }
  end
  # FreeRegistration.enabled? と同じ条件(公開した無料の版が無料・周期なし・販売中)を、出荷カタログの版に頼らず作る。
  let(:catalog) do
    data = JSON.parse(File.read(Toybaco::PlanCatalog::PATH))
    version = data['free_registration_version'] || data.dig('plans', 'free', 'versions').keys.max
    data['free_registration_version'] = version
    data.dig('plans', 'free', 'versions', version)['sellable'] = true
    Toybaco::PlanCatalog.new(data)
  end

  # 鍵は installation_configs の行だけで与える。環境変数から読み込まれて行が増えないようにする。
  around do |example|
    with_modified_env(HCAPTCHA_SITE_KEY: nil, HCAPTCHA_SERVER_KEY: nil) { example.run }
  end

  before do
    allow(Toybaco::PlanCatalog).to receive(:default).and_return(catalog)
    # GlobalConfig の値は Redis に残り、DB の transaction では戻らない。前後で消して他の example へ持ち越さない。
    GlobalConfig.clear_cache
  end

  after { GlobalConfig.clear_cache }

  def frame_src
    response.headers['Content-Security-Policy'].to_s.split(';').map(&:strip).grep(/\Aframe-src\b/)
  end

  describe 'hCaptcha の鍵を設定したとき' do
    # 上流の既定値の読み込みで、値の無い行が先にあることがある。行があれば値を入れ、無ければ作る。
    before do
      { 'HCAPTCHA_SITE_KEY' => 'site-key-fixture', 'HCAPTCHA_SERVER_KEY' => 'server-key-fixture' }.each do |name, value|
        InstallationConfig.find_or_initialize_by(name: name).update!(value: value, locked: false)
      end
      GlobalConfig.clear_cache
    end

    it 'フォームにウィジェットと送信前の確認を出し、CSP で hCaptcha の子 frame を許可する' do
      get '/toybaco/free/signup'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('class="h-captcha"', 'data-sitekey="site-key-fixture"', 'https://js.hcaptcha.com/1/api.js', guard_message)
      expect(frame_src).to eq(["frame-src 'self' #{Toybaco::PostizOrigin.fetch!} https://hcaptcha.com https://*.hcaptcha.com"])
    end

    it 'token の無い送信は hCaptcha に問い合わせず、チェックを促す文言で 422 を返す(HTML・JSON とも)' do
      expect(ChatwootCaptcha).not_to receive(:new)

      post '/toybaco/free/signup', params: form
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(missing_token_message)

      post '/toybaco/free/signup', params: form, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq('error' => missing_token_message)
      expect(User.from_email(form[:email])).to be_nil
    end

    it '空白だけの token も無いものとして扱い、hCaptcha に問い合わせず 422 を返す' do
      expect(ChatwootCaptcha).not_to receive(:new)

      post '/toybaco/free/signup', params: form.merge('h-captcha-response' => '   ')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(missing_token_message)
      expect(User.from_email(form[:email])).to be_nil
    end

    it 'hCaptcha が token を認めない送信は、検証に失敗した文言で 422 を返す(HTML・JSON とも)' do
      captcha = instance_double(ChatwootCaptcha, valid?: false)
      allow(ChatwootCaptcha).to receive(:new).with('client-token-fixture').and_return(captcha)

      post '/toybaco/free/signup', params: form.merge('h-captcha-response' => 'client-token-fixture')
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(verification_failed_message)
      expect(response.body).not_to include(missing_token_message)

      post '/toybaco/free/signup', params: form.merge(h_captcha_client_response: 'client-token-fixture'), as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq('error' => verification_failed_message)
      expect(captcha).to have_received(:valid?).twice
      expect(User.from_email(form[:email])).to be_nil
    end

    it 'hCaptcha が認めた token の送信は登録し、HTML は 303 で確認メールの案内へ送り、JSON は 202 で次の手順を返す' do
      captcha = instance_double(ChatwootCaptcha, valid?: true)
      allow(ChatwootCaptcha).to receive(:new).with('client-token-fixture').and_return(captcha)

      post '/toybaco/free/signup', params: form.merge('h-captcha-response' => 'client-token-fixture')
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to('/toybaco/free/verify-email')
      expect(User.from_email(form[:email])).not_to be_nil

      json_form = form.merge(email: "free-#{SecureRandom.hex(8)}@example.com", h_captcha_client_response: 'client-token-fixture')
      post '/toybaco/free/signup', params: json_form, as: :json
      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body).to eq('email' => json_form[:email], 'next' => 'verify_email')
      expect(captcha).to have_received(:valid?).twice
    end

    it '両方の名前で token が届いたら、h_captcha_client_response の値を hCaptcha に渡す' do
      captcha = instance_double(ChatwootCaptcha, valid?: false)
      expect(ChatwootCaptcha).to receive(:new).with('first-token').and_return(captcha)

      post '/toybaco/free/signup', params: form.merge('h_captcha_client_response' => 'first-token', 'h-captcha-response' => 'second-token')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(verification_failed_message)
    end
  end

  describe 'hCaptcha の鍵が無いとき' do
    it 'ウィジェットも送信前の確認の script も出さない' do
      get '/toybaco/free/signup'

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('h-captcha')
      expect(response.body).not_to include('<script')
      expect(response.body).not_to include(guard_message)
    end

    it '従来どおり CAPTCHA を検査せずに登録し、確認メールの案内へ 303 で送る' do
      expect(ChatwootCaptcha).not_to receive(:new)

      post '/toybaco/free/signup', params: form

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to('/toybaco/free/verify-email')
      expect(User.from_email(form[:email])).not_to be_nil
    end
  end

  # 障害対応で server key だけを空にした構成。サーバーは検査しないので、画面も部品と送信前の確認を出さない。
  describe 'HCAPTCHA_SITE_KEY だけを設定したとき' do
    before do
      { 'HCAPTCHA_SITE_KEY' => 'site-key-fixture', 'HCAPTCHA_SERVER_KEY' => '' }.each do |name, value|
        InstallationConfig.find_or_initialize_by(name: name).update!(value: value, locked: false)
      end
      GlobalConfig.clear_cache
    end

    it 'ウィジェットも送信前の確認の script も出さない' do
      get '/toybaco/free/signup'

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('h-captcha')
      expect(response.body).not_to include('<script')
      expect(response.body).not_to include(guard_message)
    end

    it 'token の無い送信を検査せずに受け付け、HTML は 303 で確認メールの案内へ送り、JSON は 202 で次の手順を返す' do
      expect(ChatwootCaptcha).not_to receive(:new)

      post '/toybaco/free/signup', params: form
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to('/toybaco/free/verify-email')
      expect(User.from_email(form[:email])).not_to be_nil

      json_form = form.merge(email: "free-#{SecureRandom.hex(8)}@example.com")
      post '/toybaco/free/signup', params: json_form, as: :json
      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body).to eq('email' => json_form[:email], 'next' => 'verify_email')
    end
  end
end
