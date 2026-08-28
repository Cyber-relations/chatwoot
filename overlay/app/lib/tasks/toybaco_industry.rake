# frozen_string_literal: true

require_relative '../toybaco/industry_pack'

namespace :toybaco do
  desc '業界パックの適用(rake toybaco:apply_industry_pack[account_id,industry])。industry省略時はアカウントに保存済みの業種を使う。冪等'
  task :apply_industry_pack, %i[account_id industry] => :environment do |_t, args|
    account = Account.find(args[:account_id].to_i)
    industry = args[:industry].presence || account.internal_attributes&.dig(Toybaco::IndustryPack::INDUSTRY_KEY)
    abort "業種が未指定です。候補: #{Toybaco::IndustryPack.known_industries.join(' ')}" if industry.blank?

    result = Toybaco::IndustryPack.apply(account, industry)
    abort "未知の業種です: #{industry}(候補: #{Toybaco::IndustryPack.known_industries.join(' ')})" if result.nil?

    puts "業界パック適用: account ##{account.id} / #{industry} / " \
         "定型文 作成#{result[:canned_created]} 更新#{result[:canned_updated]} / " \
         "ラベル 作成#{result[:labels_created]} 更新#{result[:labels_updated]}"
    puts '不在メッセージは受信箱の新規作成時に自動で入ります(既存の受信箱は設定 > 受信トレイから)'
  end
end

# 自動開通(toybaco:provision)の後段として業界パックを適用する。
# provision タスク本体には手を入れず、別ファイルからの enhance で連結する
# (lib/tasks は toybaco.rake → toybaco_industry.rake の順に読まれる)。
# payload に industry が無い・none・未知の場合は何もしない(開通自体は成功のまま)。
if Rake::Task.task_defined?('toybaco:provision')
  Rake::Task['toybaco:provision'].enhance do |_t, args|
    require 'base64'

    data = begin
      JSON.parse(Base64.strict_decode64(args[:payload].to_s))
    rescue StandardError
      nil
    end
    next if data.nil?

    industry = data['industry'].to_s.strip
    subscription_id = data['subscription_id'].to_s
    next if industry.empty? || industry == 'none' || subscription_id.empty?

    account = Account.find_each.find do |a|
      a.internal_attributes&.dig('toybaco_subscription_id') == subscription_id
    end
    next if account.nil?
    # Stripe が同一イベントを再送しても二重適用しない(冪等)
    next if account.internal_attributes&.dig(Toybaco::IndustryPack::INDUSTRY_KEY).present?

    result = Toybaco::IndustryPack.apply(account, industry)
    if result.nil?
      puts "業界パック: 未知の業種のため未適用(#{industry})。" \
           "手動: rake toybaco:apply_industry_pack[#{account.id},<industry>]"
    else
      puts "業界パック適用: account ##{account.id} / #{industry} / " \
           "定型文#{result[:canned_created] + result[:canned_updated]}件 " \
           "ラベル#{result[:labels_created] + result[:labels_updated]}件"
    end
  end
end
