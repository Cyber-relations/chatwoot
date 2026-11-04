# frozen_string_literal: true

namespace :toybaco do
  # 購読照合の行には、運営が Stripe の画面で持ち主を確かめられるよう、購読の id の末尾 6 字(sub_tail。"...<末尾 6 字>" の形。
  # toybaco:renewal_attention と同じ Toybaco::Ops::RenewalFormat.masked)を添える。購読の id の全体は出さない。
  desc '課金通知の確認待ちと、引き渡した購読照合の確認待ちを最小情報で表示する'
  task billing_ingress_attention: :environment do
    Toybaco::BillingEvent.where(state: 'attention').find_each do |event|
      puts JSON.generate(event.attributes.slice('id', 'mode', 'action', 'payload_digest', 'attempts', 'result', 'created_at'))
    end
    Toybaco::SubscriptionSyncRequest.where(state: 'attention').find_each do |request|
      fields = request.attributes.slice('id', 'mode', 'state', 'requested_revision', 'completed_revision', 'attempts', 'result')
      puts JSON.generate(fields.merge('sub_tail' => Toybaco::Ops::RenewalFormat.masked(request.subscription_id)))
    end
  end
end
