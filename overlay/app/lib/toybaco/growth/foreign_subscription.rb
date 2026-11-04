# frozen_string_literal: true

require_relative '../checkout'
require_relative 'billing_mode_client'
require_relative 'foreign_subscription_catalog'
require_relative 'foreign_subscription_rows'

# Stripe の account を共用する他製品の購読の通知を、待ちが尽きた時に確認待ちにせず閉じてよいかの判定(APP-1)。
# 正の証拠が全部そろった時だけ foreign を返す:
# 1. 自社の行が無い(ForeignSubscriptionRows。店舗に結び付いた後か自社の処理でしか書かれない行だけを見る)
# 2. Stripe の読みが成功している(既存の Checkout::Client#retrieve_subscription を、id と livemode を照らす BillingModeClient で包む。
#    env の TOYBACO_STRIPE_MODE も同じ mode であること。明細は has_more が false で 1 件以上、price と展開された product がそろう)
# 3. 購読の metadata に toybaco_ で始まる鍵が無い(大小文字を畳む。TOYBACO_ も自社)
# 4. 全ての明細の price・product が自社の目印(ForeignSubscriptionCatalog の lookup_key・price の id・product の name、price か
#    product の metadata の toybaco_ の鍵)に当たらない
# あわせて、購読の customer の id を契約記録に持つ店舗が無く(own_row)、購読を作ってから 32 日以上たっている(too_new)こと。
# 判定 5(待ちが尽きた時だけ照らす)は呼び出し側(ForeignSubscriptionReceipt・ForeignSubscriptionSync)が守る。
# foreign でない時は理由の語を返す(当たった最初の 1 つ。順は 1→2→3→4→作成からの日数): own_row・stripe_error・
# toybaco_metadata・catalog_unreadable・catalog・too_new、想定外の例外の check_error。判定の中の例外(StandardError)は全てここで握り、
# 外に漏らさない(PaymentSignature::Invalid が漏れると受付は final の payment_mismatch に、SubscriptionReconciliation::Invalid が
# 漏れると照合は binding_unresolved に変わるため)。planKey などの metadata の値は見ない。
module Toybaco::Growth::ForeignSubscription
  FOREIGN = 'foreign'
  SUBSCRIPTION_ID = /\Asub_[A-Za-z0-9]{1,200}\z/
  CUSTOMER_ID = /\Acus_[A-Za-z0-9]{1,200}\z/
  KEY_PREFIX = 'toybaco_'
  # 作って 32 日たたない購読は foreign にしない(too_new)。Stripe の画面で手で作ったばかりの自社の購読を、運営が店舗に結び付ける
  # 前に閉じないため。月払いの最初の更新(約 30 日後)の通知までは確認待ちになり、運営が手で確かめる。
  MINIMUM_AGE_SECONDS = 32 * 24 * 60 * 60
  Catalog = Toybaco::Growth::ForeignSubscriptionCatalog
  Rows = Toybaco::Growth::ForeignSubscriptionRows

  module_function

  # 理由の語(reason)と、Stripe で読んだ購読の customer(読めなければ nil)。customer は lock の中の確かめ直し(recheck)が使う。
  # catalog は PlanCatalog.default(試験は default を差し替えて注入する)。
  def judge(subscription_id:, mode:, client:, environment: ENV, now: Time.now.utc)
    return { reason: 'check_error' } unless target?(subscription_id, mode)
    return { reason: 'own_row' } if Rows.own?(subscription_id)

    subscription = read(subscription_id, mode, client, environment)
    return { reason: 'stripe_error' } unless subscription

    { reason: verdict(subscription, environment, now), customer: subscription['customer'] }
  rescue StandardError
    { reason: 'check_error' }
  end

  def check(**)
    judge(**).fetch(:reason)
  end

  def target?(subscription_id, mode)
    subscription_id.is_a?(String) && subscription_id.match?(SUBSCRIPTION_ID) && %w[test live].include?(mode)
  end

  # lock の中で、判定 1 と、判定で読んだ customer を持つ店舗を見直す(DB だけ)。判定の後に店舗が結び付いた購読や顧客を、
  # 閉じる直前に見落とさないため。savepoint の中で読み、例外は行の transaction を壊さず check_error にする。まだ foreign なら nil。
  def recheck(subscription_id, customer = nil)
    own = ActiveRecord::Base.transaction(requires_new: true) do
      Rows.own?(subscription_id) || (customer.is_a?(String) && Rows.account_holds?(customer))
    end
    'own_row' if own
  rescue StandardError
    'check_error'
  end

  # 判定 2。error・timeout・形の崩れ(metadata・明細、作った時刻 created が整数でない)・mode の違いは nil(stripe_error)。
  def read(subscription_id, mode, client, environment)
    return unless environment['TOYBACO_STRIPE_MODE'] == mode

    provider = client || Toybaco::Checkout::Client.new(environment.fetch('TOYBACO_STRIPE_KEY', ''))
    subscription = Toybaco::Growth::BillingModeClient.new(provider, mode).retrieve_subscription(subscription_id)
    subscription if subscription['metadata'].is_a?(Hash) && subscription['created'].is_a?(Integer) && items(subscription)
  rescue StandardError
    nil
  end

  def items(subscription)
    list = subscription['items']
    return unless list.is_a?(Hash) && list['has_more'] == false

    data = list['data']
    data if data.is_a?(Array) && !data.empty? && data.all? { |item| item?(item) }
  end

  # 判定 4 が使う欄が全部読める明細だけを通す(部分的な応答は stripe_error)。
  def item?(item)
    price = item['price'] if item.is_a?(Hash)
    product = price['product'] if price.is_a?(Hash)
    price?(price) && product?(product)
  end

  # price は lookup_key の鍵を必ず持ち、値は nil か文字列(Stripe の price は lookup_key が null のことが普通)。
  def price?(price)
    shaped?(price) && price.key?('lookup_key') && (price['lookup_key'].nil? || price['lookup_key'].is_a?(String))
  end

  # 展開された product。name が空でない文字列であること。削除済みの product(deleted: true、name が無い)は読めない扱い。
  def product?(product)
    shaped?(product) && product['deleted'] != true && product['name'].is_a?(String) && !product['name'].strip.empty?
  end

  # id(文字列)と metadata(Hash)を持つ Hash(price と、展開された product)。
  def shaped?(value)
    value.is_a?(Hash) && value['id'].is_a?(String) && value['metadata'].is_a?(Hash)
  end

  # Stripe の読みが要る判定(顧客・3・4・作成からの日数)。
  def verdict(subscription, environment, now)
    customer_reason(subscription) || metadata_reason(subscription) || catalog_reason(subscription, environment) ||
      too_new_reason(subscription, now) || FOREIGN
  end

  # 購読の customer の id(展開しない文字列)を internal_attributes に持つ店舗があれば自社(own_row。toybaco_stripe_customer_id が
  # これに当たる)。店舗の顧客が新しく作った購読や、購読の id を記録する前の購読を、他製品と誤って閉じないため。
  # customer が id の形でなければ stripe_error。
  def customer_reason(subscription)
    customer = subscription['customer']
    return 'stripe_error' unless customer.is_a?(String) && customer.match?(CUSTOMER_ID)

    'own_row' if Rows.account_holds?(customer)
  end

  def metadata_reason(subscription)
    'toybaco_metadata' if toybaco_key?(subscription['metadata'])
  end

  def catalog_reason(subscription, environment)
    marks = Catalog.load(environment: environment)
    items(subscription).each do |item|
      reason = item_reason(item, marks)
      return reason if reason
    end
    nil
  rescue Catalog::Unreadable
    'catalog_unreadable'
  end

  def item_reason(item, marks)
    price = item['price']
    product = price['product']
    return 'catalog' if marks.own?(price, product)

    'toybaco_metadata' if toybaco_key?(price['metadata']) || toybaco_key?(product['metadata'])
  end

  def toybaco_key?(metadata)
    metadata.is_a?(Hash) && metadata.keys.any? { |key| key.to_s.downcase.start_with?(KEY_PREFIX) }
  end

  # created は read が整数であることを確かめてある。now からちょうど 32 日前までに作った購読だけが foreign になれる。
  def too_new_reason(subscription, now)
    'too_new' unless subscription['created'] <= now.to_i - MINIMUM_AGE_SECONDS
  end
end
