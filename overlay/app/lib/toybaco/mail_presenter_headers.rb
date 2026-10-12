# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # 段 2a: 受信メールのヘッダーのうち、一斉配信・自動送信・配信不能・noreply の見分けに使うものを、upstream の headers_data
  # (content_attributes['email']['headers'])に小文字のキーで足す。転送(SES)・IMAP・Gmail・Microsoft の取り込みは
  # どれも MailPresenter を通るので、全経路で残る。upstream の 3 つ(x-original-from など)の形は変えない。
  # from・auto-submitted・x-autoreply は生値を残す。upstream の email.from は Reply-To を優先し、auto_reply は 'no' / 'yes'
  # と大小文字まで一致で判定するため(AutomatedMail は生値があればそちらで判定する)。
  # 値は文字列にして 1 つ 500 文字まで。無いヘッダーは入れない。
  module MailPresenterHeaders
    AUTOMATION_HEADERS = %w[from auto-submitted x-autoreply list-unsubscribe list-id precedence return-path x-failed-recipients
                            x-auto-response-suppress].freeze
    MAX_LENGTH = 500

    def headers_data
      added = AUTOMATION_HEADERS.each_with_object({}) do |name, result|
        fields = Array(@mail[name])
        result[name] = fields.map { |field| field.value.to_s }.join(', ')[0, MAX_LENGTH] if fields.any?
      end
      (super || {}).merge(added).presence
    end
  end
end
