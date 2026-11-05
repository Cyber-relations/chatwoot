# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::TelegramController, type: :request do
  before do
    allow(Webhooks::TelegramEventsJob).to receive(:perform_later)
  end

  it 'rejects a whitespace route credential before enqueueing' do
    post '/webhooks/telegram/%20', params: { message: { text: 'fixture' } }, as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(Webhooks::TelegramEventsJob).not_to have_received(:perform_later)
  end

  it 'preserves callbacks carrying a nonblank route credential' do
    post '/webhooks/telegram/synthetic-token', params: { message: { text: 'fixture' } }, as: :json

    expect(response).to have_http_status(:ok)
    expect(Webhooks::TelegramEventsJob).to have_received(:perform_later).with(hash_including('bot_token' => 'synthetic-token')).once
  end
end
