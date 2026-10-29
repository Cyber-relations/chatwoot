# frozen_string_literal: true

# Action Cable の logger。既定(application の logger、production は info)は購読の stream 名を
# 「RoomChannel is streaming from <pubsub token>」(actioncable 7.2 channel/streams.rb)、購読解除の identifier を
# 「Unsubscribing from channel: {"channel":"RoomChannel","pubsub_token":"…"}」(connection/subscriptions.rb)として INFO に出し、
# ERROR の行(Could not execute command from (…) など)にも identifier を載せる。web widget の訪問者は pubsub token だけで
# 購読できる(room_channel.rb)ので、ログに残った値は購読の資格になる。
#
# Action Cable 専用の logger を WARN にして INFO・DEBUG の行を出さず、残る WARN 以上の行は pubsub_token の値・HTTP widget の
# proof(tbwhttp1.…)・stream 名を [FILTERED] にしてから、application の logger(Rails.logger)へそのまま足す。出力先と
# 行の形(production の ::Logger::Formatter)は application の logger と同じ。frame・identifier・例外の文はそもそも出さない
# (CableSafeLog)。ここの伏せ字はその取りこぼしの網で、足す行は application の logger の最後の網(LogScrub)にも通す
# (Logger#<< は formatter を通らないため)。
module Toybaco::Security::CableLog
  FILTERED = '[FILTERED]'
  # "pubsub_token":"…"(identifier の JSON)、\"pubsub_token\":\"…\"(inspect の中の JSON)、"pubsub_token" => "…"・
  # pubsub_token: "…"(Hash#inspect)の値。切断後に届いた frame は生の JSON 文字列ごと inspect される
  # (Connection::Base#dispatch_websocket_message)ので、引用符の前の backslash は何本でも受ける(\\\" など)。
  # key・値・引用符の Unicode escape も、application の最後の網と同じ式で伏せる。
  TOKEN_VALUE = Toybaco::Security::LogScrub::TOKEN_VALUE
  STREAM_NAME = /((?:streaming from|Broadcasting to) )\S+/
  WIDGET_PROOF = /tbwhttp1\.[^\s"\\,)]+/

  def self.mask(message)
    message.to_s.gsub(TOKEN_VALUE, "\\1#{FILTERED}").gsub(STREAM_NAME, "\\1#{FILTERED}").gsub(WIDGET_PROOF, FILTERED)
  end

  def self.logger
    logger = ActiveSupport::Logger.new(self)
    logger.formatter = Formatter.new
    logger.level = ::Logger::WARN
    ActiveSupport::TaggedLogging.new(logger)
  end

  # Logger::LogDevice の書き先。formatter が整えた行を application の logger へそのまま足す。
  def self.write(line)
    application_logger = ::Rails.logger
    application_logger << Toybaco::Security::LogScrub.mask(line) if application_logger
    line.bytesize
  end

  def self.close; end

  class Formatter < ::Logger::Formatter
    def call(severity, time, progname, message)
      super(severity, time, progname, Toybaco::Security::CableLog.mask(msg2str(message)))
    end
  end
end
