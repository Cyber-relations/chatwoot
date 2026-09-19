# frozen_string_literal: true

require_relative '../toybaco/growth/payment_recovery'

namespace :toybaco do
  desc '確認待ちの入金受付の識別子と状態を内部表示する'
  task growth_payment_attention: :environment do
    Toybaco::GrowthPaymentEvent.where(state: 'attention').find_each do |event|
      puts JSON.generate(event.attributes.slice('id', 'action', 'payload_digest', 'attempts', 'result', 'created_at'))
    end
  end

  desc '請求運用が確認した報告書から、同じ入金受付の照合だけを再開する'
  task :review_growth_payment, [:report_path] => :environment do |_task, args|
    raw = File.open(args[:report_path], 'rb') { |file| file.read(16_385) }
    raise Toybaco::Growth::PaymentRecovery::Invalid if raw.bytesize > 16_384

    report = JSON.parse(raw, allow_duplicate_key: false, max_nesting: 8)
    puts "追加パックの入金再照合: #{Toybaco::Growth::PaymentRecovery.retry!(report)}"
  end
end
