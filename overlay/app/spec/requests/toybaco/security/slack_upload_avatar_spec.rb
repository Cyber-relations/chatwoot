# frozen_string_literal: true

require 'rails_helper'

# CASA 5.1.1: blob の無い /slack_uploads は params[:sender_type] を encode せずに代わりの画像の path に入れて redirect する
# (app/controllers/slack_uploads_controller.rb:28-31)。上流が link に入れる種類と public/integrations/slack/ の画像の名前だけを受ける。
RSpec.describe 'Slack upload fallback image', type: :request do
  # The fallback image is on FRONTEND_URL; Rails refuses a redirect to another host than the request's.
  before { host! URI.parse(ENV.fetch('FRONTEND_URL', 'http://www.example.com')).host }

  it 'redirects the sender types that upstream links to their image' do
    %w[agent bot contact system user].each do |sender_type|
      get '/slack_uploads', params: { blob_key: 'missing-blob', sender_type: sender_type }

      expect(response).to have_http_status(:found)
      expect(URI.parse(response.location).path).to eq("/integrations/slack/#{sender_type}.png")
    end
  end

  it 'answers 404 for any other sender type instead of building a path from it' do
    ['../../../app/login', 'bot.png?x=1', 'bot/../contact', 'Bot', "bot\n", '', 'https://evil.example/x'].each do |sender_type|
      get '/slack_uploads', params: { blob_key: 'missing-blob', sender_type: sender_type }

      expect(response).to have_http_status(:not_found)
      expect(response.location).to be_nil
    end
  end
end
