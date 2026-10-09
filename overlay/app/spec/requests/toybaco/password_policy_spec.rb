# frozen_string_literal: true

require 'rails_helper'

# パスワード設定(招待・再設定リンク)と自分のパスワード変更の 422 契約。
# 要件未達は日本語の full message。トークン不一致と現在のパスワード誤りは上流の英語リテラルのまま返り、
# フロント(v3/api/auth.js の toybacoPasswordError、ChangePassword.vue の toybacoPasswordAlert)が日本語へ写像する。
RSpec.describe 'Toybaco password policy', type: :request do
  describe 'PUT /auth/password' do
    let(:user) { create(:user, skip_confirmation: false) }
    let(:raw_token) { user.send(:set_reset_password_token) }

    def put_password(token, password, confirmation = password)
      put '/auth/password',
          params: { locale: 'ja', reset_password_token: token, password: password, password_confirmation: confirmation },
          as: :json
    end

    it '要件を満たさないと 422 で日本語の要件文言を返す' do
      expect(user.reload.confirmed?).to be(false)
      put_password(raw_token, 'Abcdef12')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['message']).to match(/\Aパスワード には記号を1文字以上含めてください/)
      expect(response.parsed_body['message']).not_to match(/must contain|translation missing/i)
      # 画面は確認用にも同じ値を送るので、gem は password_confirmation の内容も検証してエラーを付ける。
      expect(response.parsed_body['attributes']).to eq(%w[password password_confirmation])
      expect(response.parsed_body['message']).to include(', パスワード（確認） には記号を1文字以上含めてください')
    end

    it '不正なトークンは上流の Invalid token をそのまま返す(フロントの判定が依存する)' do
      put_password("invalid-#{SecureRandom.hex(8)}", 'Abcdef1!')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['message']).to eq('Invalid token')
    end

    it '要件を満たすと設定でき、未確認ユーザーも確認済みになる' do
      put_password(raw_token, 'Abcdef1!')

      expect(response).to have_http_status(:ok)
      expect(user.reload.confirmed?).to be(true)
      expect(user.valid_password?('Abcdef1!')).to be(true)
      # ブラウザー印の無いリクエストなので、資格情報はヘッダで返る(spec/requests/toybaco/devise_auth_headers_spec.rb と同じ)。
      expect(response.headers.values_at('access-token', 'client', 'uid')).to all(be_present)
      expect(user.valid_token?(response.headers['access-token'], response.headers['client'])).to be(true)
    end
  end

  describe 'PUT /api/v1/profile' do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }

    def put_profile(current_password, password, confirmation = password)
      put '/api/v1/profile',
          params: {
            locale: 'ja',
            profile: { current_password: current_password, password: password, password_confirmation: confirmation }
          },
          headers: user.create_new_auth_token,
          as: :json
    end

    it '要件を満たさないと 422 で日本語の要件文言を返す' do
      put_profile('Password1!', 'Abcdef12')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['message']).to match(/\Aパスワード には記号を1文字以上含めてください/)
      expect(response.parsed_body['message']).not_to match(/must contain|translation missing/i)
    end

    it '現在のパスワードが違うと上流の Invalid current password をそのまま返す(フロントの判定が依存する)' do
      put_profile('Wrong-password1!', 'Abcdef1!')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to eq('Invalid current password')
      expect(user.reload.valid_password?('Password1!')).to be(true)
    end

    it '正しい現在のパスワードと要件を満たす新しいパスワードで変更できる' do
      put_profile('Password1!', 'Abcdef1!')

      expect(response).to have_http_status(:ok)
      expect(user.reload.valid_password?('Abcdef1!')).to be(true)
    end
  end
end
