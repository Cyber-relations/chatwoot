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
# - API 型の受信箱の client API の path(/public/api/v1/inboxes/<受信箱>/contacts/<連絡先>/…)の連絡先の identifier と、その
#   path の query の source_id・contact_id。訪問者の会話を読む鍵になる(CASA 2.1.1・6.5.1)。受信箱の identifier と後ろの
#   path、ほかの query は残す。ほかの path の query は見ない。
module Toybaco::Security::LogScrub
  FILTERED = '[FILTERED]'
  FILTERED_EMAIL = '[FILTERED_EMAIL]'

  # 1 文字を、生のまま・\uXXXX(backslash は何本でも)のどちらでも受ける。
  def self.escapable(text)
    text.chars.map { |char| "(?:#{Regexp.escape(char)}|\\\\+u00#{format('%02x', char.ord)})" }.join
  end

  # Rack decodes percent escapes in every query-key character, not only the underscore.
  def self.percent_escapable(text)
    text.chars.map { |char| "(?:#{Regexp.escape(char)}|%#{format('%02x', char.ord)})" }.join
  end

  # どの式も Regexp.linear_time? が真(Ruby 3.4 の memoization で線形時間)。繰り返しの中に {n} を置かない。
  # Unicode code unit のうち 0022 (引用符)以外。lookaround や繰り返し内の {n} を使わない。
  VALUE_HEX4 = '(?:[1-9a-f][0-9a-f][0-9a-f][0-9a-f]|0[1-9a-f][0-9a-f][0-9a-f]|00[013-9a-f][0-9a-f]|002[013-9a-f])'
  QUOTE = /(?:\\*"|\\+u0022)/
  EMAIL = /[^\s@"'<>()\[\],;:\\]+(?:@|\\+u0040)(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}/i
  # identifier 内の引用符は \u0022 でもよい。閉じる引用符を値として食べず、後続の無関係な属性を保つ。
  TOKEN_VALUE = /(#{escapable('pubsub_token')}(?:#{QUOTE})?\s*(?:=(?:>|\\+u003e)|:)\s*#{QUOTE})(?:\\+u#{VALUE_HEX4}|[^"\\])*/i
  WIDGET_TOKEN = %r{\btbw(?:http|r|p)\d+\.[A-Za-z0-9._~+/=-]+}
  # Bot API credentials can occur outside params, including Rails Started paths.
  TELEGRAM_TOKEN = /\d+(?::|%3a|\\+u003a)[A-Za-z0-9_-]{30,}/i
  TELEGRAM_PATH = %r{(/webhooks/telegram/)[^\s/?"'\\]+}i
  JWT = /\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*/
  SEALED = %r{[A-Za-z0-9+/]{16,}={0,2}--[A-Za-z0-9+/]{16,}={0,2}--[A-Za-z0-9+/]{16,}={0,2}}
  PUBLIC_CONTACT_PATH = %r{(/public/api/v1/inboxes/[^\s/?"'\\]+/contacts/)[^\s/?"'\\]+}i
  # 作成の POST は query の source_id でも既存の連絡先につなぐ。key は %5F・[] を使った書き方も受ける(Rack は同じ key に読む)。
  PUBLIC_CONTACT_QUERY = %r{(/public/api/v1/inboxes/[^\s/?"'\\]+/contacts[^\s?"'\\]*\?)([^\s"'\\#]+)}i
  PUBLIC_CONTACT_QUERY_KEY = /(\A|[&;])((?:#{percent_escapable('source_id')}|#{percent_escapable('contact_id')})[^&;=]*=)[^&;]*/i
  PUBLIC_CONTACT_QUERY_MASK = ->(match) { "#{match[1]}#{match[2].gsub(PUBLIC_CONTACT_QUERY_KEY, "\\1\\2#{FILTERED}")}" }
  PUBLIC_CONTACT_RULES = [
    [%r{public/api}i, PUBLIC_CONTACT_PATH, "\\1#{FILTERED}"],
    [%r{public/api}i, PUBLIC_CONTACT_QUERY, PUBLIC_CONTACT_QUERY_MASK]
  ].freeze

  # [目印, 式, 置き換え]。目印(安い部分一致)が無い行では式を照合しない(長い行でも gsub を空振りさせない)。
  RULES = [
    [/token|\\u/i, TOKEN_VALUE, "\\1#{FILTERED}"],
    [/tbw/, WIDGET_TOKEN, FILTERED],
    [/:|%3a|u003a/i, TELEGRAM_TOKEN, FILTERED],
    [/telegram/i, TELEGRAM_PATH, "\\1#{FILTERED}"],
    [/eyJ/, JWT, FILTERED],
    [/--/, SEALED, FILTERED],
    *PUBLIC_CONTACT_RULES,
    [/@|u0040/, EMAIL, FILTERED_EMAIL]
  ].freeze

  # 同じ identifier を request の Parameters 行(lograge も同じ filtered params を読む)でも伏せる filter_parameters の block
  # (3 つ目の引数は request の params 全体)。連絡先の controller の id と source_id(作成の POST はその値で既存の連絡先に
  # つなぐ)、会話・message の controller の contact_id だけ。ほかの controller の id・contact_id・source_id は今のまま出す。
  PUBLIC_CONTACT_KEYS = %w[id source_id].freeze
  PUBLIC_CONTACT_PARAMETER = lambda do |key, value, params|
    controller = params.is_a?(Hash) ? (params['controller'] || params[:controller]).to_s : ''
    next unless value.is_a?(String) && controller.start_with?('public/api/v1/inboxes/')

    contact_key = controller == 'public/api/v1/inboxes/contacts' ? PUBLIC_CONTACT_KEYS.include?(key.to_s) : key.to_s == 'contact_id'
    value.replace(FILTERED) if contact_key
  end

  def self.mask(text)
    apply(RULES, text)
  end

  # Rails の Started の行と controller の通知の payload の path(request.filtered_path)。Rails の query の filter は key と値だけを
  # 受け取り controller を知らない(上の block は効かない)ので、公開の連絡先の path の identifier と query をここで伏せる。
  def self.mask_public_contact(text)
    apply(PUBLIC_CONTACT_RULES, text)
  end

  def self.apply(rules, text)
    return text unless text.is_a?(String)

    rules.reduce(text) do |line, (hint, pattern, replacement)|
      next line unless line.match?(hint)

      replacement.is_a?(Proc) ? line.gsub(pattern) { replacement.call(Regexp.last_match) } : line.gsub(pattern, replacement)
    end
  end
  private_class_method :apply

  # ActionDispatch::Request に prepend する(toybaco_log_redaction.rb)。元の値は Rails が memo する。伏せるのは目印のある path だけ。
  module FilteredPath
    def filtered_path
      Toybaco::Security::LogScrub.mask_public_contact(super)
    end
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
