# frozen_string_literal: true

require_relative '../toybaco/inbound_email'
require_relative '../toybaco/inbound_email/reingest'

namespace :toybaco do
  desc 'SES 受信箱を開通する(rake toybaco:provision_email_inbox[アカウント番号])。MX未整備なら作らない'
  task :provision_email_inbox, [:account_id] => :environment do |_t, args|
    account = Account.find(args[:account_id])
    result = Toybaco::InboundEmail.provision!(account)
    state = result[:created] ? '作成' : '既存'
    # ECS の task の puts は LogScrub を通らず CloudWatch に生で出る。アドレスは account から導ける local part だけを出す。
    local_part = result[:address].to_s.split('@', 2).first
    puts "メール受信箱#{state}: account ##{account.id} / #{local_part} / 受信トレイ「#{Toybaco::InboundEmail::INBOX_NAME}」"
  rescue Toybaco::InboundEmail::NotReady => e
    abort "メール受信箱を開けません(fail-closed): #{e.message}"
  end

  # DLQ に入った受信を S3 の原本から取り込み直す(Toybaco::InboundEmail::Reingest)。出力は固定語の 1 行だけで、
  # ingested / duplicate 以外(not_found / rejected / failed)は exit 1(ops-rake の run を失敗にし、監査行は failed になる)。
  desc '受信メールの原本(S3 の inbound/<SES の messageId>)を通常の SES の受信と同じ取り込みへ渡す' \
       '(rake toybaco:inbound_email_reingest[messageId])。同じ Message-ID の受信があれば重複として止める'
  task :inbound_email_reingest, [:message_id] => :environment do |_t, args|
    reingest = Toybaco::InboundEmail::Reingest
    result = args.extras.empty? ? reingest.run(args[:message_id]) : 'rejected'
    puts reingest.line(result, args[:message_id])
    exit 1 unless reingest::SUCCESS.include?(result)
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
    puts "メール受信箱#{state}: account ##{account.id} / #{result[:address].to_s.split('@', 2).first}"
  rescue Toybaco::InboundEmail::NotReady => e
    puts "メール受信箱未開通(fail-closed): #{e.message}。" \
         "MX/SES 受信が揃ってから rake toybaco:provision_email_inbox[#{account&.id}]"
  end
end
