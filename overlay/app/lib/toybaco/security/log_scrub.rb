# frozen_string_literal: true

# ログの最後の防御線(CASA 6.5.1)。Rails の logger(lograge も同じ logger に書く)と、Action Cable の logger
# (CableLog、Rails.logger へ書く行)と、Sidekiq の server の logger の全行を、出す直前に伏せる。経路ごとの上書き
# (filter_parameters・JobErrorLog・CableLog など)はそのまま残し、ここは取りこぼしの網にする。
#
# 伏せる形(式は読み込み時に一度だけ作る):
# - メールアドレスの形(@ を \u0040 と書いたものも)。
# - pubsub_token の値。key・値は生の JSON・inspect の escape(backslash の数を問わない)・\uXXXX の escape のどれでも。
#   Hash の表示の `=>` は、Rails の JSON が `>` を escape した `=\u003e` も受ける。
# - Toybaco の widget の proof・復旧・pubsub の token(tbwhttp1. / tbwr1. / tbwp1. など)。
# - JWT の形(eyJ….eyJ….…)。
# - ActiveSupport::MessageEncryptor の暗号文の形(data--iv--tag。封印した job の引数など)。
module Toybaco::Security::LogScrub
  FILTERED = '[FILTERED]'
  FILTERED_EMAIL = '[FILTERED_EMAIL]'

  # 1 文字を、生のまま・\uXXXX(backslash は何本でも)のどちらでも受ける。
  def self.escapable(text)
    text.chars.map { |char| "(?:#{Regexp.escape(char)}|\\\\+u00#{format('%02x', char.ord)})" }.join
  end

  # どの式も Regexp.linear_time? が真(Ruby 3.4 の memoization で線形時間)。繰り返しの中に {n} を置かない。
  # Unicode code unit のうち 0022 (引用符)以外。lookaround や繰り返し内の {n} を使わない。
  VALUE_HEX4 = '(?:[1-9a-f][0-9a-f][0-9a-f][0-9a-f]|0[1-9a-f][0-9a-f][0-9a-f]|00[013-9a-f][0-9a-f]|002[013-9a-f])'
  QUOTE = /(?:\\*"|\\+u0022)/
  EMAIL = /[^\s@"'<>()\[\],;:\\]+(?:@|\\+u0040)(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}/i
  # identifier 内の引用符は \u0022 でもよい。閉じる引用符を値として食べず、後続の無関係な属性を保つ。
  TOKEN_VALUE = /(#{escapable('pubsub_token')}(?:#{QUOTE})?\s*(?:=(?:>|\\+u003e)|:)\s*#{QUOTE})(?:\\+u#{VALUE_HEX4}|[^"\\])*/i
  WIDGET_TOKEN = %r{\btbw(?:http|r|p)\d+\.[A-Za-z0-9._~+/=-]+}
  JWT = /\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*/
  SEALED = %r{[A-Za-z0-9+/]{16,}={0,2}--[A-Za-z0-9+/]{16,}={0,2}--[A-Za-z0-9+/]{16,}={0,2}}

  # [目印, 式, 置き換え]。目印(安い部分一致)が無い行では式を照合しない(長い行でも gsub を空振りさせない)。
  RULES = [
    [/token|\\u/i, TOKEN_VALUE, "\\1#{FILTERED}"],
    [/tbw/, WIDGET_TOKEN, FILTERED],
    [/eyJ/, JWT, FILTERED],
    [/--/, SEALED, FILTERED],
    [/@|u0040/, EMAIL, FILTERED_EMAIL]
  ].freeze

  def self.mask(text)
    return text unless text.is_a?(String)

    RULES.reduce(text) { |line, (hint, pattern, replacement)| line.match?(hint) ? line.gsub(pattern, replacement) : line }
  end

  # logger の formatter(Logger::Formatter・ActiveSupport の formatter・TaggedLogging が拡張したもの・Sidekiq の formatter)に
  # extend する。元の formatter が作った 1 行(tag・時刻・JSON を含む)を伏せて返す。TaggedLogging#tagged が作る写し(clone)も
  # この拡張を引き継ぐ。
  module Formatter
    def call(*)
      Toybaco::Security::LogScrub.mask(super)
    end
  end

  # BroadcastLogger(Rails.logger)に extend する。後から足される logger(Sidekiq の Rails 連携の broadcast_to など)にも網を入れる。
  module Broadcast
    def broadcast_to(*loggers)
      loggers.each { |logger| Toybaco::Security::LogScrub.install(logger) }
      super
    end
  end

  # BroadcastLogger は中の logger のすべてと、後から足される logger に入れる。2 回目は何もしない。formatter の無い ::Logger は
  # 既定と同じ ::Logger::Formatter を置いてから入れる(出力の形は変わらない)。
  def self.install(logger)
    return logger if logger.nil?

    if logger.respond_to?(:broadcasts)
      logger.extend(Broadcast) unless logger.is_a?(Broadcast)
      logger.broadcasts.each { |target| install(target) }
      return logger
    end

    formatter = logger.formatter || (logger.formatter = ::Logger::Formatter.new)
    formatter.extend(Formatter) unless formatter.is_a?(Formatter)
    logger
  end
end
