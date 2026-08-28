# frozen_string_literal: true

require_relative '../toybaco/postiz_origin'

namespace :toybaco do
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
      <script src="/brand-assets/toybaco-post-entry.js" defer></script>
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
    account = Account.find(args[:account_id])
    attrs = account.internal_attributes || {}
    postiz = (attrs['postiz'] || {}).merge('enabled' => true)
    account.update!(internal_attributes: attrs.merge('postiz' => postiz))
    puts "#{account.name}(##{account.id})で投稿機能を使えるようにしました"
  end

  desc '投稿機能を止める(rake toybaco:disable_posting[アカウント番号])'
  task :disable_posting, [:account_id] => :environment do |_t, args|
    account = Account.find(args[:account_id])
    attrs = account.internal_attributes || {}
    postiz = (attrs['postiz'] || {}).merge('enabled' => false)
    account.update!(internal_attributes: attrs.merge('postiz' => postiz))
    puts "#{account.name}(##{account.id})の投稿機能を止めました"
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

  # プランごとに無効化する機能。ここに無い機能は既定(有効)のまま。
  # スターター: Instagram DM はスタンダード以上(LP の記載どおり)
  PLAN_DISABLED_FEATURES = {
    'starter' => %w[channel_instagram],
    'standard' => [],
    'business' => []
  }.freeze

  desc 'プランに応じた機能設定を適用する(rake toybaco:apply_plan[アカウント番号,プラン])'
  task :apply_plan, [:account_id, :plan] => :environment do |_t, args|
    account = Account.find(args[:account_id])
    plan = args[:plan].to_s
    disabled = PLAN_DISABLED_FEATURES[plan] or abort 'プランは starter / standard / business のいずれかです'

    # 他プランで無効化対象の機能は、このプランで対象外なら有効に戻す(プラン変更に対応)
    re_enable = PLAN_DISABLED_FEATURES.values.flatten.uniq - disabled
    account.enable_features!(*re_enable) if re_enable.any?
    account.disable_features!(*disabled) if disabled.any?

    attrs = account.internal_attributes || {}
    updates = { 'toybaco_plan' => plan }
    # スタンダード以上は投稿機能を内包する(スターターはオプション契約時に enable_posting)
    if %w[standard business].include?(plan)
      updates['postiz'] = (attrs['postiz'] || {}).merge('enabled' => true)
    end
    account.update!(internal_attributes: attrs.merge(updates))

    puts "#{account.name}(##{account.id})に #{plan} の設定を適用しました" \
         "(無効化: #{disabled.presence&.join(', ') || 'なし'} / 投稿: #{%w[standard business].include?(plan) ? '内包' : 'オプション'})"
  end

  desc 'プラン・利用状況の一覧(スターターの人数上限 3 名は目視で確認する)'
  task plan_status: :environment do
    Account.find_each do |account|
      attrs = account.internal_attributes || {}
      plan = attrs['toybaco_plan'] || '未設定'
      agents = account.account_users.count
      ig = account.feature_enabled?('channel_instagram') ? 'IG可' : 'IG不可'
      posting = attrs.dig('postiz', 'enabled') == true ? '投稿あり' : '投稿なし'
      over = plan == 'starter' && agents > 3 ? ' ★人数超過(スターターは3名まで)' : ''
      puts "##{account.id} #{account.name}: #{plan} / #{agents}名 / #{ig} / #{posting}#{over}"
    end
  end
end
