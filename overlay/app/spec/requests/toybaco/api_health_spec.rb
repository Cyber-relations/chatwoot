# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'GET /api', type: :request do
  it 'stale な PG でも verify 後は data_services=ok を返す' do
    allow(Toybaco::PostgresHealth).to receive(:verify_or_reconnect!).and_return(true)

    get '/api'

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('data_services' => 'ok')
    expect(Toybaco::PostgresHealth).to have_received(:verify_or_reconnect!)
  end

  it '張り直せなければ data_services=failing のままにする' do
    allow(Toybaco::PostgresHealth).to receive(:verify_or_reconnect!)
      .and_raise(ActiveRecord::ConnectionNotEstablished)

    get '/api'

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('data_services' => 'failing')
  end
end
