# frozen_string_literal: true

require 'rails_helper'

# CASA 6.5.1: Stripe Checkout の Session の URL(path の cs_… と fragment)は、その決済の page を開く鍵になる。Rails の
# "Redirected to" の行(redirect_to.action_controller の location)には [FILTERED] と出し、利用者は今のまま Stripe へ進む。
RSpec.describe 'Stripe Checkout redirect log line', type: :request do
  let(:terms) { Toybaco::Checkout::Catalog.sale('pro', 'year') }
  let(:checkout_url) { "https://checkout.stripe.com/c/pay/cs_test_#{SecureRandom.alphanumeric(24)}#fid#{SecureRandom.hex(8)}" }

  def logged_locations(&)
    locations = []
    callback = ->(*event) { locations << event.last[:location] }
    ActiveSupport::Notifications.subscribed(callback, 'redirect_to.action_controller', &)
    locations
  end

  # The location that ActionDispatch::Http::FilterRedirect gives the log line for a redirect of this application.
  def filtered(location)
    redirect = ActionDispatch::Response.new
    redirect.request = ActionDispatch::Request.new(Rails.application.env_config.merge(Rack::MockRequest.env_for('/')))
    redirect.location = location
    redirect.filtered_location
  end

  it 'logs [FILTERED] for the Checkout Session redirect while the buyer still goes to Stripe' do
    allow(Toybaco::Checkout).to receive(:start!).and_return({ 'url' => checkout_url })

    locations = logged_locations do
      post '/toybaco/checkout', params: { plan: 'pro', cycle: 'year', version: terms['plan_version'], accept_terms: '1' },
                                headers: { 'Origin' => 'http://www.example.com', 'Sec-Fetch-Site' => 'same-origin' }
    end

    expect(response).to redirect_to(checkout_url)
    expect(locations).to eq(['[FILTERED]'])
  end

  it 'keeps every other redirect location in the log line' do
    ['http://www.example.com/app/accounts/1/settings/inboxes?toybaco_connection=connected', 'https://billing.stripe.com/p/session/x',
     '/app/login'].each do |location|
      expect(filtered(location)).to eq(location)
    end
    expect(filtered('https://checkout.stripe.com/c/pay/cs_live_x#y')).to eq('[FILTERED]')
  end
end
