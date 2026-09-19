# frozen_string_literal: true

require_relative '../toybaco/growth/pack_fulfillment'
require_relative '../toybaco/growth/pack_refund'

namespace :toybaco do
  desc 'Stripeの実入金と追加パック注文を照合し、一度だけ付与する'
  task :complete_growth_pack, [:session_id, :event_id] => :environment do |_task, args|
    client = Toybaco::Checkout::Client.new(ENV.fetch('TOYBACO_STRIPE_KEY', ''))
    result = Toybaco::Growth::PackFulfillment.new(client: client).complete!(args[:session_id], args[:event_id])
    puts "追加パックの入金照合: #{result}"
  end

  desc '追加パックの返金・異議申立てを照合し、未使用枠を停止する'
  task :reconcile_growth_pack_refund, [:charge_id] => :environment do |_task, args|
    client = Toybaco::Checkout::Client.new(ENV.fetch('TOYBACO_STRIPE_KEY', ''))
    result = Toybaco::Growth::PackRefund.new(client: client).call(args[:charge_id])
    puts "追加パックの返金照合: #{result}"
  end
end
