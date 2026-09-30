# frozen_string_literal: true

require 'rails_helper'
require 'csv'
require 'stringio'
require Rails.root.join('lib/toybaco/ops/store_index')

# 運営の店舗一覧(S1-2)の画面と CSV。サインイン・DB flag・列の値・CSV の形・絞込・SQL の本数を確かめる。
RSpec.describe 'SuperAdmin toybaco stores', type: :request do
  # 2026-09-28 16:30 UTC = 2026-09-29 01:30 JST(日付が JST で変わる時刻にして、表示と CSV のファイル名が JST であることを見る)。
  let(:now) { Time.utc(2026, 9, 28, 16, 30, 0) }
  let(:super_admin) { create(:super_admin) }
  let(:catalog) { Toybaco::PlanCatalog.default }

  before do
    travel_to now
    # Ruby だけの fixture で実際の layout・navigation を描画する(assets の検証は production image の smoke が別に行う)。
    allow(ViteRuby.instance).to receive(:dev_server_running?).and_return(true)
    console(true)
  end

  # フラグは installation_configs を直接読む(Toybaco::Ops::OpsFlag)ので、stub ではなく toybaco:ops_flag と同じ形の行
  # (locked: true)を置く。nil は行なし。
  def console(value)
    InstallationConfig.unscoped.where(name: 'TOYBACO_OPS_CONSOLE_ENABLED').delete_all
    InstallationConfig.create!(name: 'TOYBACO_OPS_CONSOLE_ENABLED', value: value, locked: true) unless value.nil?
  end

  def contract(plan, version, cycle: 'month')
    Toybaco::Entitlements.snapshot_for(catalog.definition(plan, version), cycle: cycle)
  end

  def store(name, terms = nil, users: 0, attrs: {}, status: 'active')
    account = create(:account, name: name, status: status)
    users.times { create(:user, account: account) }
    Toybaco::Entitlements.apply!(account, terms) if terms
    account.update!(internal_attributes: account.reload.internal_attributes.merge(attrs)) if attrs.any?
    account.reload
  end

  def table
    page = Nokogiri::HTML(response.body)
    headers = page.css('table thead th').map { |cell| cell.text.strip }
    page.css('table tbody tr').to_h { |tr| [tr['data-store-id'].to_i, headers.zip(tr.css('td').map { |cell| cell.text.strip }).to_h] }
  end

  def csv_rows
    CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true).map(&:to_h)
  end

  def sync_request(state, account_id: nil, subscription_id: "sub_#{SecureRandom.hex(6)}")
    Toybaco::SubscriptionSyncRequest.create!(subscription_id: subscription_id, mode: 'test', state: state, account_id: account_id,
                                             deadline_at: now + 1.day, next_attempt_at: now, next_enqueue_at: now)
  end

  def posting_authority(account, state)
    authority_id = SecureRandom.hex(32)
    Toybaco::GrowthPostingAuthority.create!(account_id: account.id, authority_id: authority_id, preparation_request_id: SecureRandom.uuid,
                                            receipt: { 'fixture' => true }, state: state, created_at: now, updated_at: now)
    Toybaco::GrowthPostingAuthorityCurrent.create!(account_id: account.id, generation: 1, epoch: SecureRandom.hex(32),
                                                   authority_id: authority_id, created_at: now, updated_at: now)
  end

  def ai_grant(account, units:, used:)
    Toybaco::GrowthAiGrant.create!(account: account, source: 'included', source_key: "paid:sub_#{account.id}:1:base", units: units,
                                   used: used, starts_at: now - 5.days, ends_at: now + 25.days)
  end

  # 4 店舗: 人数超過のライト / 支払保留のスタンダード / 契約なしで停止中 / 保存された契約が壊れた店舗。
  def build_stores
    light_attrs = { 'toybaco_subscription_status' => 'active', 'toybaco_cancel_at_period_end' => true }
    light = store('花屋テスト店', contract('light', '2026-09-06.1'), users: 4, attrs: light_attrs)
    create_list(:inbox, 2, :with_email, account: light)
    inbox = create(:inbox, account: light)
    create(:conversation, account: light, inbox: inbox).update_columns(last_activity_at: now - 2.hours) # rubocop:disable Rails/SkipsModelValidations
    light.users.first.update_columns(current_sign_in_at: now - 1.hour) # rubocop:disable Rails/SkipsModelValidations
    standard_attrs = { 'toybaco_subscription_status' => 'past_due', 'toybaco_billing_payment_pending' => true }
    standard = store('パン屋テスト店', contract('standard', '2026-09-25.1', cycle: 'year'), users: 1, attrs: standard_attrs)
    ai_grant(standard, units: 500, used: 120)
    posting_authority(standard, 'active')
    sync_request('pending', account_id: standard.id)
    unset = store('美容室テスト店', status: 'suspended', attrs: { 'toybaco_subscription_id' => 'sub_unset' })
    sync_request('attention', subscription_id: 'sub_unset')
    broken = store('契約不正テスト店', users: 1, attrs: { 'toybaco_contract' => { 'schema_version' => 2 } })
    [light, standard, unset, broken]
  end

  def expected_rows(light, standard, unset, broken)
    {
      light.id => ['花屋テスト店', '人数超過', 'light', '2026-09-06.1', 'month', 'active', '解約予約', '4', '3', '3',
                   'Email 2・WebWidget 1', '無効', '—', '無効', '0', '0', '0', '2026-09-29 00:30', '2026-09-29'],
      standard.id => ['パン屋テスト店', '支払保留', 'standard', '2026-09-25.1', 'year', 'past_due', '支払保留・照合中', '1', '—', '0',
                      '—', '有効', 'active', '有効', '120', '500', '380', '—', '2026-09-29'],
      unset.id => ['美容室テスト店', '停止・照合要確認', '未設定', '—', '—', '—', '停止・照合要確認', '0', '—', '0', '—', '無効', '—',
                   '無効', '0', '0', '0', '—', '2026-09-29'],
      broken.id => ['契約不正テスト店', '人数超過', '契約不正', '—', '—', '—', '—', '1', '0', '0', '—', '無効', '—', '契約不正', '—', '—', '—',
                    '—', '2026-09-29']
    }
  end

  describe 'サインインと DB flag' do
    it '未サインインは SuperAdmin のサインイン画面へ送り、CSV も渡さない' do
      store('非公開の店舗')
      get '/super_admin/toybaco_stores'
      expect(response).to have_http_status(:found)
      expect(response.location).to end_with('/super_admin/sign_in')
      get '/super_admin/toybaco_stores.csv'
      expect(response).not_to have_http_status(:ok)
      expect(response.body).not_to include('非公開の店舗')
    end

    it 'DB flag が true 以外なら 404 にし、ナビゲーションにもリンクを出さない' do
      sign_in_admin_with_mfa(super_admin)
      [false, nil, 'true'].each do |value|
        console(value)
        get '/super_admin/toybaco_stores'
        expect(response).to have_http_status(:not_found)
        get '/super_admin/toybaco_stores.csv'
        expect(response).to have_http_status(:not_found)
      end
      get '/super_admin/accounts'
      expect(response.body).not_to include('href="/super_admin/toybaco_stores"')
      console(true)
      get '/super_admin/accounts'
      expect(response.body).to include('href="/super_admin/toybaco_stores"')
    end

    it 'GlobalConfig の cache に古い true が残っていても、DB に行が無ければ 404 にしてリンクも出さない(フラグは DB を直接読む)' do
      sign_in_admin_with_mfa(super_admin)
      console(nil)
      Redis::Alfred.set("#{GlobalConfig::VERSION}:#{GlobalConfig::KEY_PREFIX}:TOYBACO_OPS_CONSOLE_ENABLED", { value: true }.to_json)
      get '/super_admin/toybaco_stores'
      expect(response).to have_http_status(:not_found)
      get '/super_admin/accounts'
      expect(response.body).not_to include('href="/super_admin/toybaco_stores"')
    ensure
      GlobalConfig.clear_cache
    end
  end

  describe '一覧' do
    before { sign_in_admin_with_mfa(super_admin) }

    it '店舗ごとに契約・Stripe 状態・担当者・受信箱・投稿・AI・最終活動・開通日を JST で出す' do
      stores = build_stores
      get '/super_admin/toybaco_stores'
      expect(response).to have_http_status(:ok)
      actual = table.slice(*stores.map(&:id)).transform_values { |cells| cells.values.drop(1) }
      expect(actual).to eq(expected_rows(*stores))
      expect(table.keys).to eq(stores.values_at(0, 3, 2, 1).map(&:id))
      expect(response.body).to include('href="/super_admin/toybaco_stores"', '列の見方', 'このページを CSV で保存')
      expect(%w[Cache-Control X-Content-Type-Options].map { |key| response.headers[key] }).to eq(['private, no-store', 'nosniff'])
    end

    it '1 店舗の保存値の型が崩れていても、その店舗だけ契約不正にして画面・CSV・要確認の絞込を出す' do
      normal = store('普通の店', contract('standard', '2026-09-25.1'))
      broken = store('型の崩れた店', users: 1)
      # 通常の保存は投稿連携の検査が同じ値で失敗するので、崩れた保存値は直接書く(Entitlements は TypeError を出す)。
      broken.update_columns(internal_attributes: { 'toybaco_plan' => 'starter', 'postiz' => false }) # rubocop:disable Rails/SkipsModelValidations
      expect { Toybaco::Entitlements.contract_for(broken) }.to raise_error(TypeError)
      pages = ['/super_admin/toybaco_stores', '/super_admin/toybaco_stores.csv', '/super_admin/toybaco_stores?state=attention'].map do |path|
        get path
        [response.status, path.include?('.csv') ? csv_rows.index_by { |row| row.fetch('店舗ID').to_i } : table]
      end
      html, csv, attention = pages.map(&:last)
      expect(pages.map(&:first)).to eq([200, 200, 200])
      expect([html, csv].map { |rows| rows.fetch(broken.id).values_at('プラン', 'AI', '担当者上限', '要確認') })
        .to eq([%w[契約不正 契約不正 0 人数超過]] * 2)
      expect([html.fetch(normal.id)['プラン'], attention.keys]).to eq(['standard', [broken.id]])
    end

    it 'HTML と CSV 以外の形式は 404 にする' do
      store('形式を選ぶ店')
      get '/super_admin/toybaco_stores.json'
      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include('形式を選ぶ店')
    end

    it '付随情報は各店舗の分だけを数え、他の店舗の値を混ぜない' do
      busy = store('受信箱の多い店', contract('standard', '2026-09-25.1'), users: 3)
      create_list(:inbox, 3, account: busy)
      ai_grant(busy, units: 500, used: 77)
      posting_authority(busy, 'stale')
      quiet = store('静かな店', contract('standard', '2026-09-25.1'))
      ai_grant(quiet, units: 500, used: 0)
      get '/super_admin/toybaco_stores'
      rows = table
      values = ['担当者数', '受信箱数', '受信箱内訳', '投稿権限', 'AI 使用', 'AI 残り']
      expect(rows.fetch(busy.id).values_at(*values)).to eq(['3', '3', 'WebWidget 3', 'stale', '77', '423'])
      expect(rows.fetch(quiet.id).values_at(*values)).to eq(['0', '0', '—', '—', '0', '500'])
    end

    it '一覧の表示で店舗名と数値をログに出さない' do
      build_stores
      log = StringIO.new
      logger = ActiveSupport::Logger.new(log, level: :info)
      [Rails, ActionController::Base, ActionView::Base, ActiveRecord::Base].each { |owner| allow(owner).to receive(:logger).and_return(logger) }
      get '/super_admin/toybaco_stores'
      get '/super_admin/toybaco_stores.csv'
      expect(response).to have_http_status(:ok)
      expect(log.string).not_to include('花屋テスト店', 'パン屋テスト店', '2026-09-06.1', 'past_due')
    end
  end

  describe 'CSV' do
    before { sign_in_admin_with_mfa(super_admin) }

    it 'BOM 付き UTF-8 で、画面と同じ列・JST の日付のファイル名で渡す' do
      stores = build_stores
      get '/super_admin/toybaco_stores.csv'
      expect(response).to have_http_status(:ok)
      headers = %w[Content-Type Content-Disposition Cache-Control X-Content-Type-Options].index_with { |key| response.headers[key] }
      expect(headers).to eq('Content-Type' => 'text/csv; charset=utf-8',
                            'Content-Disposition' => 'attachment; filename="toybaco-stores-20260929.csv"',
                            'Cache-Control' => 'private, no-store', 'X-Content-Type-Options' => 'nosniff')
      expect(response.body.b).to start_with("\xEF\xBB\xBF".b)
      expect(csv_rows.first.keys).to eq(Toybaco::Ops::StoreColumns::HEADERS)
      actual = csv_rows.to_h { |row| [row.fetch('店舗ID').to_i, row.values.drop(1).map(&:to_s)] }
      expect(actual.slice(*stores.map(&:id))).to eq(expected_rows(*stores))
    end

    it '数式として読まれる先頭文字に引用符を付け、利用者の氏名・メールアドレスを含めない' do
      names = ['=HYPERLINK("https://example.invalid","x")', '+1 店', '-1 店', '@SUM(A1)', "\tタブの店", "\r改行の店", "\n改行 LF の店",
               '|cmd', ' =SUM(A1)', "\u00A0@NBSP の店", "\u3000=全角空白の店", '普通の店']
      accounts = names.map { |name| store(name) }
      create(:user, account: accounts.last, name: '個人情報 太郎', email: 'owner-pii@example.invalid')
      get '/super_admin/toybaco_stores.csv'
      exported = csv_rows.to_h { |row| [row.fetch('店舗ID').to_i, row.fetch('店舗名')] }
      expect(accounts.map { |account| exported.fetch(account.id) })
        .to eq(names.first(11).map { |name| "'#{name}" } + ['普通の店'])
      expect(response.body).not_to include('個人情報 太郎', 'owner-pii@example.invalid')
    end
  end

  describe '絞込・並び・ページ' do
    before { sign_in_admin_with_mfa(super_admin) }

    it 'プラン・状態で絞り込み、開通日の降順にも並べ替える' do
      light, standard, unset, broken = build_stores
      { { plan: 'light' } => [light], { plan: 'none' } => [unset], { state: 'suspended' } => [unset],
        { state: 'payment_pending' } => [standard], { state: 'cancel_scheduled' } => [light],
        { state: 'active' } => [light, broken, standard], { state: 'attention' } => [light, broken, unset, standard],
        { plan: 'standard', state: 'attention' } => [standard] }.each do |params, expected|
        get '/super_admin/toybaco_stores', params: params
        expect([params, table.keys]).to eq([params, expected.map(&:id)])
      end
      { broken => now - 1.day, unset => now - 3.days, light => now - 2.days, standard => now - 4.days }.each do |account, opened|
        account.update_columns(created_at: opened) # rubocop:disable Rails/SkipsModelValidations
      end
      get '/super_admin/toybaco_stores', params: { sort: 'opened' }
      expect(table.keys).to eq([broken, light, unset, standard].map(&:id))
    end

    it '許可した値以外は 400 にする' do
      [{ page: '0' }, { page: '1001' }, { page: 'x' }, { plan: 'enterprise' }, { state: 'deleted' }, { sort: 'name' },
       { 'plan[]' => 'light' }].each do |params|
        get '/super_admin/toybaco_stores', params: params
        expect([params, response.status]).to eq([params, 400])
      end
      get '/super_admin/toybaco_stores.csv', params: { page: '1001' }
      expect(response).to have_http_status(:bad_request)
      get '/super_admin/toybaco_stores', params: { page: '1000' }
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'SQL の本数' do
    before { sign_in_admin_with_mfa(super_admin) }

    def count_queries(&)
      count = 0
      counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
      count
    end

    # 一覧の全ての付随情報の読み出しを通す店舗を count 件足す: 担当者 2 名・受信箱・AI の枠と有効な予約を全店舗に、
    # 投稿権限・購読の照合(attention)を最初の店舗に、フリー復帰の記録を最後の店舗(id が最大 = 1 ページ目)に持たせる。
    def add_stores(count) # rubocop:disable Metrics/AbcSize
      attrs = Toybaco::Entitlements.project_attributes({}, contract('standard', '2026-09-25.1'))
      pointer = { Toybaco::Growth::FreeReturnRecord::KEY => { 'transition_id' => 'a' * 64, 'returned_at' => now.to_i, 'receipt_hash' => 'b' * 64 } }
      ids = Account.insert_all!(Array.new(count) do |index| # rubocop:disable Rails/SkipsModelValidations
        { name: "一括店舗#{index}", status: 0, internal_attributes: index == count - 1 ? attrs.merge(pointer) : attrs, created_at: now, updated_at: now }
      end, returning: [:id]).rows.flatten
      members = create_list(:user, 2)
      AccountUser.insert_all!(ids.product(members).map { |id, user| { account_id: id, user_id: user.id, role: 0, created_at: now, updated_at: now } }) # rubocop:disable Rails/SkipsModelValidations
      inboxes = ids.map { |id| { account_id: id, channel_id: id, channel_type: 'Channel::Email', name: '受信箱', created_at: now, updated_at: now } }
      Inbox.insert_all!(inboxes) # rubocop:disable Rails/SkipsModelValidations
      add_ai_ledger(ids)
      posting_authority(Account.find(ids.first), 'active')
      sync_request('attention', account_id: ids.first)
      ids
    end

    # 全店舗に AI の枠(500 回中 3 回使用)と有効な予約 1 件を持たせる。
    def add_ai_ledger(ids)
      grants = Toybaco::GrowthAiGrant.insert_all!(ids.map do |id| # rubocop:disable Rails/SkipsModelValidations
        { account_id: id, source: 'included', source_key: "paid:sub_#{id}:1:base", units: 500, used: 3, starts_at: now - 1.day, ends_at: now + 1.day,
          created_at: now, updated_at: now }
      end, returning: %i[id account_id]).rows
      Toybaco::GrowthAiOperation.insert_all!(grants.map do |grant_id, account_id| # rubocop:disable Rails/SkipsModelValidations
        { account_id: account_id, grant_id: grant_id, request_key: SecureRandom.uuid, kind: 'reply_draft', context_digest: SecureRandom.hex(32),
          token_digest: SecureRandom.hex(32), lease_expires_at: now + 1.minute, created_at: now, updated_at: now }
      end)
    end

    def counts
      listed = count_queries { Toybaco::Ops::StoreIndex.new(now: now).rows }
      attention = count_queries { Toybaco::Ops::StoreIndex.new(now: now, state: 'attention').rows }
      html = count_queries { get '/super_admin/toybaco_stores' }
      csv = count_queries { get '/super_admin/toybaco_stores.csv' }
      { listed: listed, attention: attention, html: html, csv: csv }
    end

    # 画面の本数には administrate のレイアウト(上流)が引く InstallationConfig・SuperAdmin の読み出し(店舗数によらない定数)が含まれる。
    # 一覧自身の SQL(店舗・受信箱・投稿権限・予約ダウングレード・フリー復帰の記録・付与枠と有効な予約の数、の各 1 本)と、
    # レイアウトを描かない CSV のリクエスト全体(サインインの読み出しを含む)を 12 本以内で見る。
    # 要確認で絞り込む一覧は、人数超過の判定(全店舗の契約と account_users の件数)の 2 本を足して 14 本以内。
    it '120 店舗でも本数は店舗数によらず、一覧の SQL と CSV のリクエストは 12 本以内(要確認の絞込は 14 本以内)' do
      small_ids = add_stores(2)
      # サインイン直後の 1 回目は Devise の最終ログイン更新、2 回目までは上流の設定値の初回作成・読み出しが入るので、揃えてから数える。
      2.times { get '/super_admin/toybaco_stores' }
      small = counts
      ids = small_ids + add_stores(118)
      large = counts
      expect(large).to eq(small)
      expect([large[:listed], large[:csv], large[:attention] - 2]).to all(be <= 12)
      get '/super_admin/toybaco_stores'
      first_page = [table.keys, table.fetch(ids.max)['AI'], table.values.second.values_at('AI 使用', 'AI 上限', 'AI 残り')]
      expect(first_page).to eq([ids.sort.last(100).reverse, '要確認', %w[3 500 496]])
      expect(response.body).to include('page=2', '次の100件')
      expect(count_queries { get '/super_admin/toybaco_stores', params: { page: '2' } }).to eq(large[:html])
      expect(table.keys).to eq(ids.sort.first(20).reverse)
      expect(response.body).not_to include('次の100件')
    end
  end
end
