# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # アプリが Stripe API を呼ぶときの API version を、この 1 か所で固定する(Stripe-Version ヘッダー)。
  # 送らないと Stripe はアカウントの既定版で解釈するため、Dashboard 側の既定版の変更で応答の形が変わりうる。
  # 版を上げるときは、この定数を変えて staging で Checkout・Webhook の受入を取り直してから production へ出す。
  # Webhook のイベントの形は Dashboard の webhook endpoint 側の API version で決まり、この定数では変わらない。
  module StripeApi
    VERSION = '2026-06-24.dahlia'
    VERSION_FORMAT = /\A\d{4}-\d{2}-\d{2}\.[a-z]+\z/
    HEADER = 'Stripe-Version'

    raise ArgumentError, "invalid Stripe API version: #{VERSION.inspect}" unless VERSION.match?(VERSION_FORMAT)
  end
end
