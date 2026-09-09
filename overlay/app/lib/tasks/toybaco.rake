# frozen_string_literal: true

require_relative '../toybaco/brand_injector'
require_relative '../toybaco/entitlements'
require_relative '../toybaco/subscription_sync'
require_relative '../toybaco/store_fulfillment'
require 'digest'

# Independent rake task declarations share one namespace.
namespace :toybaco do # rubocop:disable Metrics/BlockLength
  desc '最新の決済契約と利用権を照合する'
  task :sync_subscription, [:subscription_id] => :environment do |_t, args|
    id = args[:subscription_id].to_s
    abort 'サブスクリプションIDが不正です。' unless id.match?(/\Asub_[A-Za-z0-9]+\z/)
    ActiveRecord::Base.transaction do
      # 開通のStripe読取後からcommit前のイベントも、同じ契約の開通完了を待って再照合する。
      lock_id = Digest::SHA256.digest("toybaco:provision:#{id}").unpack1('q>')
      ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{lock_id})")
      accounts = Account.where("internal_attributes ->> 'toybaco_subscription_id' = ?", id).order(:id).to_a
      if accounts.empty?
        # 未作成なら後続provisionが最新Stripe契約を読む。ここでは権利を作らず成功とも記録しない。
        puts '契約照合: status=DEFERRED reason=not_provisioned'
        next
      end
      client = Toybaco::Checkout::Client.new(ENV.fetch('TOYBACO_STRIPE_KEY', nil))
      accounts.each do |account|
        result = Toybaco::StoreFulfillment.synchronize(account, subscription_id: id, client: client)
        puts "契約照合: account ##{account.id} / #{result}"
      end
    end
  end

  desc 'Chatwoot の installation_configs をトイバコブランドに合わせる'
  task branding: :environment do
    updates = {
      'INSTALLATION_NAME' => 'トイバコ',
      'BRAND_NAME' => 'トイバコ',
      'BRAND_URL' => 'https://toybaco.jp',
      'WIDGET_BRAND_URL' => 'https://toybaco.jp',
      'LOGO' => '/brand-assets/toybaco-logo-c4.png',
      'LOGO_DARK' => '/brand-assets/toybaco-logo-c4-dark.png',
      'LOGO_THUMBNAIL' => '/brand-assets/toybaco-mark-c4.png',
      'TERMS_URL' => 'https://toybaco.jp/terms',
      'PRIVACY_URL' => 'https://toybaco.jp/privacy',
      # Chatwoot 既定メタデータ(アップデートバナー・BuildInfo のバージョン表記)を出さない
      'DISPLAY_MANIFEST' => false
    }

    updates.each do |name, value|
      rec = InstallationConfig.find_or_initialize_by(name: name)
      rec.value = value
      rec.locked = false
      rec.save!
      puts "updated #{name}"
    end

    GlobalConfig.clear_cache
    puts 'toybaco branding applied'
  end

  desc '互換用: 受信箱の「投稿」入口をDASHBOARD_SCRIPTSにも登録する(通常は自動読込)'
  task post_entry: :environment do
    # 通常は Toybaco::BrandInjector が標準HTML応答へ自動注入する。このタスクは
    # 旧環境との互換用であり、同じ検証済みorigin以外を保存しない。
    post_url = Toybaco::PostizOrigin.fetch!
    # ご契約内容(Stripe カスタマーポータルのログインページ)。プラン変更・カード変更・解約が顧客だけで完結する
    billing_url = ENV.fetch('TOYBACO_BILLING_URL', 'https://billing.stripe.com/p/login/28E00l3TTdn3bX40cy4F200')
    script = <<~HTML
      <script>window.TOYBACO_POST_URL=#{post_url.to_json};window.TOYBACO_BILLING_URL=#{billing_url.to_json};</script>
      #{Toybaco::BrandInjector::POST_ENTRY_ASSET}
    HTML

    rec = InstallationConfig.find_or_initialize_by(name: 'DASHBOARD_SCRIPTS')
    rec.value = script
    rec.locked = false
    rec.save!

    GlobalConfig.clear_cache
    puts "post entry installed (#{post_url})"
  end

  desc '「投稿」への入口を取り下げる'
  task post_entry_remove: :environment do
    rec = InstallationConfig.find_by(name: 'DASHBOARD_SCRIPTS')
    if rec
      rec.value = ''
      rec.save!
      GlobalConfig.clear_cache
    end
    puts 'post entry removed'
  end

  desc '投稿機能を使えるようにする(rake toybaco:enable_posting[アカウント番号])'
  task :enable_posting, [:account_id] => :environment do |_t, args|
    Toybaco::StoreFulfillment.with_account(args[:account_id]) do |account|
      attrs = account.internal_attributes || {}
      postiz = (attrs['postiz'] || {}).merge('enabled' => true)
      addons = Array(attrs['toybaco_contract_addons']).reject { |item| item['id'] == 'manual-posting' }
      addons << Toybaco::Entitlements.new_addon('manual-posting', quantity: 1, source: 'manual')
      contract = Toybaco::Entitlements.contract_for(account)
      contract = contract.merge('addons' => addons) if contract
      account.update!(internal_attributes: attrs.merge('postiz' => postiz, 'toybaco_contract_addons' => addons, 'toybaco_contract' => contract))
      puts "#{account.name}(##{account.id})で投稿機能を使えるようにしました"
    end
  end

  desc '投稿機能を止める(rake toybaco:disable_posting[アカウント番号])'
  task :disable_posting, [:account_id] => :environment do |_t, args|
    Toybaco::StoreFulfillment.with_account(args[:account_id]) do |account|
      attrs = account.internal_attributes || {}
      postiz = (attrs['postiz'] || {}).merge('enabled' => false)
      addons = Array(attrs['toybaco_contract_addons']).reject { |item| item['id'] == 'manual-posting' }
      contract = Toybaco::Entitlements.contract_for(account)
      contract = contract.merge('addons' => addons) if contract
      account.update!(internal_attributes: attrs.merge('postiz' => postiz, 'toybaco_contract_addons' => addons, 'toybaco_contract' => contract))
      puts "#{account.name}(##{account.id})の投稿機能を止めました"
    end
  end

  desc '投稿機能の利用状況を一覧する'
  task posting_status: :environment do
    Account.find_each do |account|
      postiz = account.internal_attributes&.dig('postiz') || {}
      state = postiz['enabled'] == true ? '利用中' : '未契約'
      org = postiz['organization_id'] ? " / 投稿側ID: #{postiz['organization_id']}" : ''
      puts "##{account.id} #{account.name}: #{state}#{org}"
    end
  end

  desc '明示した契約版の機能を適用する(rake toybaco:apply_plan[account_id,plan,version,cycle])'
  task :apply_plan, [:account_id, :plan, :version, :cycle] => :environment do |_t, args|
    account = Account.find(args[:account_id])
    old = Toybaco::Entitlements.contract_for(account)
    plan = args[:plan].to_s
    version = args[:version].presence
    # Reapplying an existing plan retains its purchased terms, including legacy contracts.
    if old && old['plan_id'] == plan && !version
      contract = old
    else
      abort '変更先の契約版を指定してください。' unless version
      terms = Toybaco::PlanCatalog.default.definition(plan, version)
      contract = Toybaco::Entitlements.snapshot_for(
        terms, cycle: args[:cycle].presence || old&.dig('cycle'), addons: old ? old.fetch('addons') : []
      )
    end
    Toybaco::Entitlements.apply!(account, contract)
    puts "#{account.name}(##{account.id})に #{plan}/#{contract.fetch('plan_version')} の設定を適用しました"
  end

  desc '決済完了からのアカウント自動開通(rake toybaco:provision[Base64のJSON])。冪等'
  # Keep the provisioning transaction and its advisory lock in one task.
  task :provision, [:payload] => :environment do |_t, args| # rubocop:disable Metrics/BlockLength
    require 'base64'
    require 'securerandom'
    require 'digest'

    data = JSON.parse(Base64.strict_decode64(args[:payload].to_s))
    email = data.fetch('email').to_s.strip.downcase
    name = data['name'].presence || email.split('@').first
    plan = data.fetch('plan')
    posting = data['posting'] == true
    subscription_id = data.fetch('subscription_id')
    catalog = Toybaco::PlanCatalog.default
    version = data['plan_version'].presence
    terms = version ? catalog.definition(plan, version) : catalog.legacy(plan)
    addons = posting ? [{ 'id' => 'manual-posting', 'quantity' => 1, 'source' => 'legacy_manual' }] : []
    contract = Toybaco::Entitlements.snapshot_for(terms, cycle: data['cycle'].presence,
                                                         reference_price_id: data['reference_price_id'], addons: addons)
    abort 'メールが不正です' unless email.match?(URI::MailTo::EMAIL_REGEXP)

    abort 'サブスクリプションIDが不正です' unless subscription_id.to_s.match?(/\Asub_[A-Za-z0-9]+\z/)

    ActiveRecord::Base.transaction do
      # アカウント作成前なので行ロックだけでは重複開通を防げない。同じ契約の再送を直列化する。
      lock_id = Digest::SHA256.digest("toybaco:provision:#{subscription_id}").unpack1('q>')
      ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{lock_id})")
      existing = Account.where("internal_attributes ->> 'toybaco_subscription_id' = ?", subscription_id).first
      client = Toybaco::Checkout::Client.new(ENV.fetch('TOYBACO_STRIPE_KEY', nil))
      if existing
        Toybaco::StoreFulfillment.synchronize(existing, subscription_id: subscription_id, client: client)
        puts "既に開通済み: account ##{existing.id}(subscription #{subscription_id})"
        next
      end

      user = User.from_email(email)
      if user.nil?
        user = User.new(name: name, email: email, password: "#{SecureRandom.alphanumeric(20)}aA1!")
        user.skip_confirmation! # パスワード設定メール(下記)に一本化する
        user.save!
      end

      account = Account.create!(
        name: name, locale: 'ja', internal_attributes: { 'toybaco_billing_owner_user_id' => user.id }
      )
      AccountUser.create!(account: account, user: user, role: :administrator)

      Toybaco::Entitlements.apply!(account, contract, subscription_id: subscription_id)
      Toybaco::StoreFulfillment.synchronize(account, subscription_id: subscription_id, client: client)

      # 初回設定・再設定共通のメールから、顧客自身がパスワードを設定する。
      user.send_reset_password_instructions
      puts "開通完了: account ##{account.id} #{name} / #{email} / #{plan}" \
           "#{posting ? ' / 投稿オプション' : ''} / subscription #{subscription_id}"
    end
  end

  desc '監査済みの契約・既存ユーザー対応を契約者未設定の親店舗へ明示適用する'
  task :assign_billing_owner, [:account_id, :user_id, :expected_subscription_id] => :environment do |_t, args| # rubocop:disable Metrics/BlockLength
    account_id, user_id = %i[account_id user_id].map do |key|
      value = args[key].to_s
      abort '店舗IDとユーザーIDは正の整数で指定してください。' unless value.match?(/\A[1-9]\d*\z/)

      Integer(value, 10)
    end
    subscription_id = args[:expected_subscription_id].to_s
    abort 'サブスクリプションIDが不正です。' unless subscription_id.match?(/\Asub_[A-Za-z0-9]+\z/)

    Account.transaction do
      account = Account.lock.find(account_id)
      attrs = Toybaco::Entitlements.attributes(account)
      abort '対象店舗と指定した契約が一致しません。' unless attrs['toybaco_subscription_id'] == subscription_id
      abort '追加店舗へ契約者を直接設定することはできません。' if attrs.key?(Toybaco::StoreFulfillment::PURCHASE)

      membership = account.account_users.lock.find_by(user_id: user_id)
      abort '対象店舗に所属する既存ユーザーを指定してください。' unless membership && User.exists?(id: user_id)

      owner_key = 'toybaco_billing_owner_user_id'
      owner_id = attrs[owner_key]
      unless owner_id.nil? || (owner_id.is_a?(Integer) && owner_id.positive? && owner_id == user_id)
        abort '契約者は別のユーザーに設定済みか、保存値が不正です。上書きは行いません。'
      end
      account.update!(internal_attributes: attrs.merge(owner_key => user_id)) if owner_id.nil?
      puts owner_id.nil? ? '契約者を設定しました。' : '同じ契約者が設定済みです。'
    end
  end

  desc '支払済み追加店舗の明細を別Light店舗へ手動開通する。再実行は同じ店舗を返す'
  task :fulfill_store, [:parent_account_id, :subscription_item_id, :administrator_id, :name] => :environment do |_t, args|
    client = Toybaco::Checkout::Client.new(ENV.fetch('TOYBACO_STRIPE_KEY', nil))
    child = Toybaco::StoreFulfillment.fulfill(
      parent_id: Integer(args[:parent_account_id], 10), item_id: args[:subscription_item_id],
      administrator_id: Integer(args[:administrator_id], 10), name: args[:name], client: client
    )
    puts "追加店舗開通: account ##{child.id} / #{child.internal_attributes.fetch('toybaco_plan')}"
  end

  # ライト(旧 starter)の担当者 3 名は Toybaco::AgentSeatLimit がサーバ強制する。
  desc 'プラン・利用状況の一覧(ライトの人数上限 3 名は担当者追加で強制する)'
  task plan_status: :environment do
    Account.find_each do |account|
      attrs = account.internal_attributes || {}
      plan = attrs['toybaco_plan'] || '未設定'
      agents = account.account_users.count
      ig = account.feature_enabled?('channel_instagram') ? 'IG可' : 'IG不可'
      posting = attrs.dig('postiz', 'enabled') == true ? '投稿あり' : '投稿なし'
      limit = Toybaco::AgentSeatLimit.limit_for(account)
      over = limit && agents > limit ? " ★人数超過(この契約は#{limit}名まで)" : ''
      puts "##{account.id} #{account.name}: #{plan} / #{agents}名 / #{ig} / #{posting}#{over}"
    end
  end
end
