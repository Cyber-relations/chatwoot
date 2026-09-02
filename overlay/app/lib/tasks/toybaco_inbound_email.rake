# frozen_string_literal: true

require_relative '../toybaco/inbound_email'

namespace :toybaco do
  desc 'SES 受信箱を開通する(rake toybaco:provision_email_inbox[アカウント番号])。MX未整備なら作らない'
  task :provision_email_inbox, [:account_id] => :environment do |_t, args|
    account = Account.find(args[:account_id])
    result = Toybaco::InboundEmail.provision!(account)
    state = result[:created] ? '作成' : '既存'
    puts "メール受信箱#{state}: account ##{account.id} / #{result[:address]} / 受信トレイ「#{Toybaco::InboundEmail::INBOX_NAME}」"
  rescue Toybaco::InboundEmail::NotReady => e
    abort "メール受信箱を開けません(fail-closed): #{e.message}"
  end
end

# 自動開通の後段。本体の開通は成功させ、受信箱だけ fail-closed で止める。
# 握りつぶして「開通済み」と見せない。ログに理由を残す。
if Rake::Task.task_defined?('toybaco:provision')
  Rake::Task['toybaco:provision'].enhance do |_t, args|
    require 'base64'

    data = begin
      JSON.parse(Base64.strict_decode64(args[:payload].to_s))
    rescue StandardError
      nil
    end
    next if data.nil?

    subscription_id = data['subscription_id'].to_s
    next if subscription_id.empty?

    account = Account.find_each.find do |row|
      row.internal_attributes&.dig('toybaco_subscription_id') == subscription_id
    end
    next if account.nil?

    result = Toybaco::InboundEmail.provision!(account)
    state = result[:created] ? '作成' : '既存'
    puts "メール受信箱#{state}: account ##{account.id} / #{result[:address]}"
  rescue Toybaco::InboundEmail::NotReady => e
    puts "メール受信箱未開通(fail-closed): #{e.message}。" \
         "MX/SES 受信が揃ってから rake toybaco:provision_email_inbox[#{account&.id}]"
  end
end
