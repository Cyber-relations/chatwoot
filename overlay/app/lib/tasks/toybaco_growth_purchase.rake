# frozen_string_literal: true

require_relative '../toybaco/growth/purchase_fulfillment'

namespace :toybaco do
  desc '既存店舗のWeb決済をStripeの最新状態と照合して同じ店舗に適用する'
  task :complete_growth_checkout, [:session_id] => :environment do |_task, args|
    client = Toybaco::Checkout::Client.new(ENV.fetch('TOYBACO_STRIPE_KEY', ''))
    result = Toybaco::Growth::PurchaseFulfillment.new(client: client).complete!(args[:session_id])
    puts "既存店舗の決済照合: #{result}"
  end
end
