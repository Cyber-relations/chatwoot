# frozen_string_literal: true

require 'json'
require 'time'
require_relative '../toybaco/growth/trial_compensation'

namespace :toybaco do
  desc '確認済み自社障害の対象店舗へ体験時間を補填する（内部運用専用）'
  task :compensate_trial, [:report_path] => :environment do |_task, args|
    # The reviewed operational report contains identifiers, never credentials.
    raw = File.open(args[:report_path].to_s, 'rb') { |file| file.read(65_537) }
    abort '障害記録が大きすぎます。' if raw.bytesize > 65_536
    data = JSON.parse(raw, allow_duplicate_key: false)
    fields = %w[account_id confirmed incident_key report_digest operator_reference starts_at ends_at]
    abort '確認済み障害記録の項目が不正です。' unless data.is_a?(Hash) && data.keys.sort == fields.sort
    abort '対象店舗が不正です。' unless data['account_id'].is_a?(Integer) && data['account_id'].positive?
    account = Account.find(data.delete('account_id'))
    %w[starts_at ends_at].each { |key| data[key] = Time.iso8601(data.fetch(key)) }
    result = Toybaco::Growth::TrialCompensation.new(account).apply!(**data.symbolize_keys)
    puts "体験補填: account_id=#{account.id} result=#{result.fetch('result')} seconds_added=#{result.fetch('seconds_added')}"
  end
end
