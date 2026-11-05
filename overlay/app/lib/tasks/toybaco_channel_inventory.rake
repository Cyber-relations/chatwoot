# frozen_string_literal: true

namespace :toybaco do
  # 提供していない接続先(SMS・Twilio・WhatsApp・X)の channel の行の件数だけを出す。名前・id・店舗は出さない。
  desc '提供外の接続先の channel の行の件数を、種類・provider・medium・音声ごとに出す'
  task unavailable_channel_inventory: :environment do
    Toybaco::ChannelInventory.lines.each { |line| puts line }
  end
end
