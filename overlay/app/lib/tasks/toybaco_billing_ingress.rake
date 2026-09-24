# frozen_string_literal: true

namespace :toybaco do
  desc '課金通知の確認待ちと、引き渡した購読照合の確認待ちを最小情報で表示する'
  task billing_ingress_attention: :environment do
    Toybaco::BillingEvent.where(state: 'attention').find_each do |event|
      puts JSON.generate(event.attributes.slice('id', 'mode', 'action', 'payload_digest', 'attempts', 'result', 'created_at'))
    end
    Toybaco::SubscriptionSyncRequest.where(state: 'attention').find_each do |request|
      puts JSON.generate(request.attributes.slice('id', 'mode', 'state', 'requested_revision', 'completed_revision', 'attempts', 'result'))
    end
  end
end
