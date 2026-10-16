# frozen_string_literal: true

require 'rails_helper'

# API・管理画面の endpoint × 役割の行列(CASA 2.3.3 / 3.3.1 の判断材料、2026-10-15)。
# 固定 upstream と overlay の現在の挙動を、代表 endpoint ごとに役割別の HTTP status で固定する。挙動は変えない。
# 資格情報は経路の実際の使われ方に合わせる:
#   /api/v1・/platform・/enterprise … 利用者・bot・platform app・super admin とも自分の静的 api_access_token(header)
#   /super_admin・/monitoring … super admin はパスワード+バックアップコードでサインインした管理画面 session、他は静的 token
#   /toybaco … 店舗の利用者は実際のブラウザーサインインで受け取るダッシュボード cookie、bot・platform app は静的 token、
#              super admin は管理画面 session
# 各 example の説明は「区分 | METHOD path | 役割または条件 | 期待 status」。scripts/generate-api-role-matrix-doc.py が
# RSpec JSON の description をこの区切りで読み、docs/growth-release-20260918/api-role-matrix-20261015.md の表を作る。
RSpec.describe 'Toybaco API role matrix', type: :request do
  roles = {
    anonymous: '匿名',
    agent: 'agent',
    administrator: 'administrator',
    billing_owner: 'billing owner',
    agent_bot: 'agent_bot token',
    platform_app: 'platform app token',
    super_admin: 'super admin',
    other_account_user: '他店舗の user'
  }
  # 期待は roles の並び(匿名, agent, administrator, billing owner, agent_bot, platform app, super admin, 他店舗)。
  denied_admin = [302, 302, 302, 302, 302, 302, 200, 302]
  members_read = [401, 200, 200, 200, 401, 401, 401, 401]
  admins_write = [401, 401, 200, 200, 401, 401, 401, 401]
  endpoints = [
    ['account', :get, '/api/v1/accounts/{店舗}', :api, -> { "/api/v1/accounts/#{account.id}" }, nil,
     [401, 200, 200, 200, 401, 401, 404, 404]],
    ['account', :patch, '/api/v1/accounts/{店舗}', :api, -> { "/api/v1/accounts/#{account.id}" }, -> { { name: '行列で変更' } },
     [401, 401, 200, 200, 401, 401, 404, 404]],
    ['inbox', :get, '/api/v1/accounts/{店舗}/inboxes', :api, -> { "/api/v1/accounts/#{account.id}/inboxes" }, nil, members_read],
    ['inbox', :patch, '/api/v1/accounts/{店舗}/inboxes/{受信箱}', :api, -> { "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}" },
     -> { { name: '行列で変更' } }, admins_write],
    ['conversation', :get, '/api/v1/accounts/{店舗}/conversations', :api, -> { "/api/v1/accounts/#{account.id}/conversations" }, nil,
     members_read],
    ['conversation', :get, '/api/v1/accounts/{店舗}/conversations/{会話}', :api,
     -> { "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}" }, nil, [401, 200, 200, 200, 200, 401, 401, 401]],
    ['conversation', :post, '/api/v1/accounts/{店舗}/conversations/{会話}/messages', :api,
     -> { "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages" }, -> { { content: '行列からの送信' } },
     [401, 200, 200, 200, 200, 401, 401, 401]],
    ['contact', :get, '/api/v1/accounts/{店舗}/contacts', :api, -> { "/api/v1/accounts/#{account.id}/contacts" }, nil, members_read],
    ['contact', :get, '/api/v1/accounts/{店舗}/contacts/{連絡先}', :api,
     -> { "/api/v1/accounts/#{account.id}/contacts/#{conversation.contact_id}" }, nil, members_read],
    ['contact', :delete, '/api/v1/accounts/{店舗}/contacts/{連絡先}', :api,
     -> { "/api/v1/accounts/#{account.id}/contacts/#{conversation.contact_id}" }, nil, admins_write],
    ['agent', :get, '/api/v1/accounts/{店舗}/agents', :api, -> { "/api/v1/accounts/#{account.id}/agents" }, nil, members_read],
    ['agent', :patch, '/api/v1/accounts/{店舗}/agents/{agent}', :api, -> { "/api/v1/accounts/#{account.id}/agents/#{users[:agent].id}" },
     -> { { agent: { name: '行列で変更' } } }, admins_write],
    ['agent_bot', :get, '/api/v1/accounts/{店舗}/agent_bots', :api, -> { "/api/v1/accounts/#{account.id}/agent_bots" }, nil, members_read],
    ['agent_bot', :post, '/api/v1/accounts/{店舗}/agent_bots', :api, -> { "/api/v1/accounts/#{account.id}/agent_bots" },
     -> { { name: '行列で作成' } }, admins_write],
    ['profile', :get, '/api/v1/profile', :api, -> { '/api/v1/profile' }, nil, [401, 200, 200, 200, 401, 401, 200, 200]],
    ['platform', :get, '/platform/api/v1/accounts/{店舗}', :platform, -> { "/platform/api/v1/accounts/#{account.id}" }, nil,
     [401, 401, 401, 401, 401, 200, 401, 401]],
    ['platform', :get, '/platform/api/v1/users/{administrator}', :platform, -> { "/platform/api/v1/users/#{users[:administrator].id}" }, nil,
     [401, 401, 401, 401, 401, 200, 401, 401]],
    ['super_admin', :get, '/super_admin', :admin, -> { '/super_admin' }, nil, denied_admin],
    ['super_admin', :get, '/super_admin/accounts/{店舗}', :admin, -> { "/super_admin/accounts/#{account.id}" }, nil, denied_admin],
    ['super_admin', :get, '/super_admin/users', :admin, -> { '/super_admin/users' }, nil, denied_admin],
    ['super_admin', :get, '/super_admin/toybaco_stores', :admin, -> { '/super_admin/toybaco_stores' }, nil, denied_admin],
    ['super_admin', :get, '/monitoring/sidekiq', :admin, -> { '/monitoring/sidekiq' }, nil, denied_admin],
    ['toybaco', :get, '/toybaco/billing?account_id={店舗}', :toybaco, -> { "/toybaco/billing?account_id=#{account.id}" }, nil,
     [401, 403, 403, 200, 401, 401, 401, 403]],
    ['toybaco', :get, '/toybaco/billing/access?account_id={店舗}', :toybaco, -> { "/toybaco/billing/access?account_id=#{account.id}" }, nil,
     [401, 200, 200, 200, 401, 401, 401, 403]],
    ['toybaco', :get, '/toybaco/agent_seat_limit?account_id={店舗}', :toybaco, -> { "/toybaco/agent_seat_limit?account_id=#{account.id}" },
     nil, [401, 200, 200, 200, 401, 401, 401, 403]],
    ['toybaco', :get, '/toybaco/ai_reply_mode?account_id={店舗}', :toybaco, -> { "/toybaco/ai_reply_mode?account_id=#{account.id}" }, nil,
     [401, 200, 200, 200, 200, 401, 401, 401]],
    ['toybaco', :put, '/toybaco/ai_reply_mode?account_id={店舗}', :toybaco, -> { "/toybaco/ai_reply_mode?account_id=#{account.id}" },
     -> { { mode: 'draft' } }, [401, 200, 200, 200, 401, 401, 401, 401]],
    ['toybaco', :get, '/toybaco/ai_usage?account_id={店舗}', :toybaco, -> { "/toybaco/ai_usage?account_id=#{account.id}" }, nil,
     [401, 200, 200, 200, 200, 401, 401, 401]],
    ['toybaco', :post, '/toybaco/ai_usage', :toybaco, -> { '/toybaco/ai_usage' }, -> { ai_usage_params },
     [401, 401, 401, 401, 200, 401, 401, 401]],
    ['enterprise(本番 CE では経路なし)', :post, '/enterprise/api/v1/accounts/{店舗}/checkout', :api,
     -> { "/enterprise/api/v1/accounts/#{account.id}/checkout" }, nil, [401, 401, 403, 422, 401, 401, 404, 404]]
  ]
  # 一覧 endpoint の許可セルで店舗分離を見るための、項目の位置・比べる鍵・自店舗の値・他店舗の値。
  # 会話の id は店舗ごとの番号で他店舗と重なるので uuid で比べる。受信箱に bot があると会話は pending で始まり、既定の
  # 一覧(open だけ)に出ないので、自店舗の会話は open にしてから比べる(他店舗の会話は bot なしの受信箱で open)。
  list_checks = {
    '/api/v1/accounts/{店舗}/conversations' =>
      [%w[data payload], 'uuid', -> { conversation.update!(status: :open) && [conversation.uuid] },
       -> { other_account.conversations.open.pluck(:uuid) }],
    '/api/v1/accounts/{店舗}/contacts' => [%w[payload], 'id', -> { [conversation.contact_id] }, -> { other_account.contacts.ids }],
    '/api/v1/accounts/{店舗}/inboxes' => [%w[payload], 'id', -> { [inbox.id] }, -> { other_account.inboxes.ids }],
    '/api/v1/accounts/{店舗}/agents' => [[], 'id', -> { [users[:agent].id, users[:administrator].id] }, -> { other_account.users.ids }],
    '/api/v1/accounts/{店舗}/agent_bots' => [[], 'id', -> { [agent_bot.id] }, -> { other_account.agent_bots.ids }]
  }

  let(:account) { create(:account, name: "行列店舗-#{SecureRandom.hex(4)}") }
  let(:other_account) { create(:account, name: "他店舗-#{SecureRandom.hex(4)}") }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  # 行列の agent_bot 列は店舗に属さない bot(account_id なし)を受信箱に割り当てたもの。店舗所属の bot は失効の節で測る。
  let(:agent_bot) { create(:agent_bot) }
  let(:platform_app) { create(:platform_app) }
  # 他店舗の object。名前は他店舗名で始め、全 example の前に作る(一覧の店舗分離・越境・拒否本文の確認に使う)。
  let(:other_inbox) { create(:inbox, account: other_account, name: "#{other_account.name}-受信箱") }
  let(:other_conversation) { create_list(:conversation, 2, account: other_account, inbox: other_inbox).last }
  let(:other_agent_bot) { create(:agent_bot, account: other_account, name: "#{other_account.name}-bot") }
  let(:browser_headers) { { 'X-Toybaco-Browser' => '1', 'Origin' => 'https://chatwoot.test', 'Sec-Fetch-Site' => 'same-origin' } }
  let(:users) do
    {
      agent: create(:user, account: account, role: :agent),
      administrator: create(:user, account: account, role: :administrator),
      billing_owner: create(:user, account: account, role: :administrator),
      other_account_user: create(:user, account: other_account, role: :administrator, name: "#{other_account.name}-利用者"),
      # 本番の SuperAdmin は MFA 登録が必須なので、静的 token の行も MFA 登録済みの SuperAdmin で測る。
      super_admin: create(:super_admin, otp_secret: User.generate_otp_secret, otp_required_for_login: true, otp_backup_codes: ['MATRIX01'])
    }
  end

  before do
    allow(ViteRuby.instance).to receive(:dev_server_running?).and_return(true)
    host! 'chatwoot.test'
    https!
    contract = Toybaco::Entitlements.snapshot_for(Toybaco::PlanCatalog.default.definition('pro', '2026-09-06.1'), cycle: 'month')
    Toybaco::Entitlements.apply!(account, contract)
    account.update!(internal_attributes: account.reload.internal_attributes.merge(Toybaco::BillingAccess::OWNER_KEY => users[:billing_owner].id))
    create(:inbox_member, inbox: inbox, user: users[:agent])
    create(:agent_bot_inbox, agent_bot: agent_bot, inbox: inbox)
    platform_app.platform_app_permissibles.create!(permissible: account)
    platform_app.platform_app_permissibles.create!(permissible: users[:administrator])
    InstallationConfig.unscoped.where(name: 'TOYBACO_OPS_CONSOLE_ENABLED').delete_all
    InstallationConfig.create!(name: 'TOYBACO_OPS_CONSOLE_ENABLED', value: true, locked: true)
    other_conversation.contact.update!(name: "#{other_account.name}-連絡先")
    other_agent_bot
  end

  def ai_usage_params
    message = create(:message, account: account, inbox: inbox, conversation: conversation)
    { account_id: account.id, conversation_id: conversation.display_id, message_id: message.id, action_type: 'reserve' }
  end

  def static_token(role)
    owner = { agent_bot: agent_bot, platform_app: platform_app }.fetch(role) { users.fetch(role) }
    owner.access_token.token
  end

  # 実ブラウザーと同じ CSRF 付きのサインインで、HttpOnly のダッシュボード cookie を受け取る。
  def sign_in_dashboard(user)
    get '/toybaco/browser-session', headers: browser_headers
    csrf = response.parsed_body.fetch('csrf_token')
    post '/auth/sign_in', params: { email: user.email, password: 'Password1!' }, headers: browser_headers.merge('X-CSRF-Token' => csrf), as: :json
    raise 'synthetic dashboard sign-in failed' unless response.status == 200 && cookies['cw_d_session_info'].present?
  end

  def credential_headers(role, surface)
    return {} if role == :anonymous

    if role == :super_admin && %i[admin toybaco].include?(surface)
      sign_in_admin_with_mfa(users[:super_admin])
      return {}
    end
    if surface == :toybaco && users.key?(role)
      sign_in_dashboard(users.fetch(role))
      return browser_headers
    end
    { 'api_access_token' => static_token(role) }
  end

  def request_as(role, verb, surface, path, params)
    headers = credential_headers(role, surface)
    public_send(verb, instance_exec(&path), params: params && instance_exec(&params), headers: headers, as: (:json if params))
  end

  # 拒否の応答本文に、対象店舗(既定は自店舗。越境では他店舗)の名前が出ていないこと(拒否が情報を返していないことの
  # 最低限の確認)。302 はサインイン画面への転送であること。
  def expect_no_store_data_on_denial(status, store: account)
    return if status < 300

    expect(response.body).not_to include(store.name)
    expect(response.location).to end_with('/super_admin/sign_in') if status == 302
  end

  # 許可された一覧の店舗分離: 他店舗の object の id と名前が応答に無く、自店舗の object はある(取り出し方の空振りでない)こと。
  def expect_store_isolated_listing(check, own_values)
    listed = listed_values(check)
    foreign_values = instance_exec(&check.fetch(3))
    expect(foreign_values).not_to be_empty
    expect(listed).to include(*own_values)
    expect(listed & foreign_values).to be_empty
    other_store_names.each { |name| expect(response.body).not_to include(name) }
  end

  def listed_values(check)
    dig_path, key = check
    items = dig_path.empty? ? response.parsed_body : response.parsed_body.dig(*dig_path)
    items.map { |item| item.fetch(key) }
  end

  def other_store_names
    [other_account.name, other_inbox.name, other_conversation.contact.name, users[:other_account_user].name, other_agent_bot.name]
  end

  endpoints.each do |row|
    group, verb, display, surface, path, params, statuses = row
    list_check = list_checks[display] if verb == :get
    roles.each_with_index do |(role, label), index|
      expected = statuses.fetch(index)
      it "#{group} | #{verb.to_s.upcase} #{display} | #{label} | #{expected}" do
        own_values = instance_exec(&list_check[2]) if list_check && expected == 200
        request_as(role, verb, surface, path, params)
        expect(response).to have_http_status(expected)
        expect_no_store_data_on_denial(expected)
        expect_store_isolated_listing(list_check, own_values) if own_values
      end
    end
  end

  describe '越境(他店舗の object・店舗)' do
    def admin_token
      { 'api_access_token' => users[:administrator].access_token.token }
    end

    it '越境 | GET /api/v1/accounts/{他店舗} | 自店舗 administrator の静的 token | 404' do
      get "/api/v1/accounts/#{other_account.id}", headers: admin_token
      expect(response).to have_http_status(:not_found)
      expect_no_store_data_on_denial(404, store: other_account)
    end

    it '越境 | GET /api/v1/accounts/{他店舗}/conversations | 自店舗 administrator の静的 token | 401' do
      get "/api/v1/accounts/#{other_account.id}/conversations", headers: admin_token
      expect(response).to have_http_status(:unauthorized)
      expect_no_store_data_on_denial(401, store: other_account)
    end

    it '越境 | GET /api/v1/accounts/{店舗}/conversations/{他店舗だけにある番号} | 自店舗 administrator の静的 token | 404' do
      conversation
      expect(account.conversations.where(display_id: other_conversation.display_id)).to be_empty
      get "/api/v1/accounts/#{account.id}/conversations/#{other_conversation.display_id}", headers: admin_token
      expect(response).to have_http_status(:not_found)
      expect_no_store_data_on_denial(404, store: other_account)
    end

    it '越境 | GET /api/v1/accounts/{店舗}/contacts/{他店舗の連絡先} | 自店舗 administrator の静的 token | 404' do
      get "/api/v1/accounts/#{account.id}/contacts/#{other_conversation.contact_id}", headers: admin_token
      expect(response).to have_http_status(:not_found)
      expect_no_store_data_on_denial(404, store: other_account)
    end

    it '越境 | PATCH /api/v1/accounts/{店舗}/inboxes/{他店舗の受信箱} | 自店舗 administrator の静的 token | 404' do
      patch "/api/v1/accounts/#{account.id}/inboxes/#{other_inbox.id}", params: { name: '越境で変更' }, headers: admin_token, as: :json
      expect(response).to have_http_status(:not_found)
      expect_no_store_data_on_denial(404, store: other_account)
      expect(other_inbox.reload.name).not_to eq('越境で変更')
    end

    it '越境 | PATCH /api/v1/accounts/{店舗}/agents/{他店舗の user} | 自店舗 administrator の静的 token | 404' do
      target = users[:other_account_user]
      patch "/api/v1/accounts/#{account.id}/agents/#{target.id}", params: { agent: { name: '越境で変更' } }, headers: admin_token, as: :json
      expect(response).to have_http_status(:not_found)
      expect_no_store_data_on_denial(404, store: other_account)
      expect(target.reload.name).not_to eq('越境で変更')
    end

    it '越境 | GET /api/v1/accounts/{他店舗}/conversations/{会話} | 自店舗の受信箱に割り当てた agent_bot token | 401' do
      get "/api/v1/accounts/#{other_account.id}/conversations/#{other_conversation.display_id}",
          headers: { 'api_access_token' => agent_bot.access_token.token }
      expect(response).to have_http_status(:unauthorized)
      expect_no_store_data_on_denial(401, store: other_account)
    end

    it '越境 | GET /platform/api/v1/accounts/{他店舗} | 自店舗だけを許可した platform app token | 401' do
      get "/platform/api/v1/accounts/#{other_account.id}", headers: { 'api_access_token' => platform_app.access_token.token }
      expect(response).to have_http_status(:unauthorized)
      expect_no_store_data_on_denial(401, store: other_account)
    end

    it '越境 | GET /toybaco/billing?account_id={他店舗} | 自店舗 billing owner のダッシュボード cookie | 403' do
      sign_in_dashboard(users[:billing_owner])
      get "/toybaco/billing?account_id=#{other_account.id}", headers: browser_headers
      expect(response).to have_http_status(:forbidden)
      expect_no_store_data_on_denial(403, store: other_account)
    end

    it '越境 | GET /toybaco/ai_reply_mode?account_id={他店舗} | 自店舗の受信箱に割り当てた agent_bot token | 401' do
      get "/toybaco/ai_reply_mode?account_id=#{other_account.id}", headers: { 'api_access_token' => agent_bot.access_token.token }
      expect(response).to have_http_status(:unauthorized)
      expect_no_store_data_on_denial(401, store: other_account)
    end
  end

  describe '失効(削除・再発行・所属解除の直後)' do
    # 店舗所属の bot(account_id 付き)。upstream は bot の店舗接続を「店舗所属」か「受信箱の割り当て」のどちらかで認める。
    let(:store_bot) { create(:agent_bot, account: account, name: "店舗所属bot-#{SecureRandom.hex(4)}") }

    def profile_status(token)
      get '/api/v1/profile', headers: { 'api_access_token' => token }
      response.status
    end

    def conversation_status(token)
      get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}", headers: { 'api_access_token' => token }
      response.status
    end

    def reply_mode_status(token)
      get "/toybaco/ai_reply_mode?account_id=#{account.id}", headers: { 'api_access_token' => token }
      response.status
    end

    it '失効 | GET /api/v1/profile | 再発行前の user 静的 token(再発行は本人の API) | 401' do
      old = static_token(:agent)
      post '/api/v1/profile/reset_access_token', headers: { 'api_access_token' => old }
      expect(response).to have_http_status(:ok)
      expect(profile_status(old)).to eq(401)
      expect_no_store_data_on_denial(401)
      expect(profile_status(users[:agent].reload.access_token.token)).to eq(200)
    end

    it '失効 | GET /api/v1/accounts/{店舗}/conversations | 再発行前の user 静的 token | 401' do
      old = static_token(:administrator)
      users[:administrator].access_token.regenerate_token
      get "/api/v1/accounts/#{account.id}/conversations", headers: { 'api_access_token' => old }
      expect(response).to have_http_status(:unauthorized)
      expect_no_store_data_on_denial(401)
    end

    it '失効 | GET /api/v1/profile | 削除した user 静的 token | 401' do
      token = static_token(:agent)
      expect(profile_status(token)).to eq(200)
      users[:agent].access_token.destroy!
      expect(profile_status(token)).to eq(401)
      expect_no_store_data_on_denial(401)
    end

    it '失効 | GET /api/v1/accounts/{店舗}/conversations | 店舗の所属を外した user の静的 token | 401' do
      token = static_token(:administrator)
      AccountUser.find_by!(account: account, user: users[:administrator]).destroy!
      get "/api/v1/accounts/#{account.id}/conversations", headers: { 'api_access_token' => token }
      expect(response).to have_http_status(:unauthorized)
      expect_no_store_data_on_denial(401)
      expect(profile_status(token)).to eq(200)
    end

    it '失効 | GET /api/v1/accounts/{店舗}/conversations | 停止した店舗の administrator の静的 token | 401' do
      account.update!(status: :suspended)
      get "/api/v1/accounts/#{account.id}/conversations", headers: { 'api_access_token' => static_token(:administrator) }
      expect(response).to have_http_status(:unauthorized)
      expect_no_store_data_on_denial(401)
    end

    it '失効 | GET /api/v1/accounts/{店舗}/conversations/{会話} | 再発行前の agent_bot token | 401' do
      old = static_token(:agent_bot)
      expect(conversation_status(old)).to eq(200)
      agent_bot.access_token.regenerate_token
      expect(conversation_status(old)).to eq(401)
      expect_no_store_data_on_denial(401)
      expect(conversation_status(agent_bot.reload.access_token.token)).to eq(200)
    end

    it '失効 | GET /api/v1/accounts/{店舗}/conversations/{会話} | 削除した agent_bot の token | 401' do
      token = static_token(:agent_bot)
      agent_bot.destroy!
      expect(conversation_status(token)).to eq(401)
      expect_no_store_data_on_denial(401)
    end

    it '失効 | GET /api/v1/accounts/{店舗}/conversations/{会話} | 受信箱の割り当てを外した店舗に属さない agent_bot の token | 401' do
      token = static_token(:agent_bot)
      expect(agent_bot.account_id).to be_nil
      AgentBotInbox.find_by!(agent_bot: agent_bot, inbox: inbox).destroy!
      expect(conversation_status(token)).to eq(401)
      expect_no_store_data_on_denial(401)
    end

    # 現行挙動の固定: 店舗所属の bot は受信箱の割り当てを外しても、店舗所属だけで店舗の会話を読める(upstream の仕様)。
    it '失効 | GET /api/v1/accounts/{店舗}/conversations/{会話} | 受信箱の割り当てを外した店舗所属 agent_bot の token | 200' do
      link = create(:agent_bot_inbox, agent_bot: store_bot, inbox: inbox)
      token = store_bot.access_token.token
      expect(conversation_status(token)).to eq(200)
      link.destroy!
      expect(store_bot.reload.agent_bot_inboxes).to be_empty
      expect(conversation_status(token)).to eq(200)
    end

    # Toybaco の AI 応答モードは受信箱の割り当てだけで bot の店舗を判定するので、店舗所属の bot でも割り当て解除で 401 になる。
    it '失効 | GET /toybaco/ai_reply_mode?account_id={店舗} | 受信箱の割り当てを外した店舗所属 agent_bot の token | 401' do
      link = create(:agent_bot_inbox, agent_bot: store_bot, inbox: inbox)
      token = store_bot.access_token.token
      expect(reply_mode_status(token)).to eq(200)
      link.destroy!
      expect(reply_mode_status(token)).to eq(401)
      expect_no_store_data_on_denial(401)
    end

    it '失効 | GET /platform/api/v1/accounts/{店舗} | 削除した platform app の token | 401' do
      token = static_token(:platform_app)
      platform_app.destroy!
      get "/platform/api/v1/accounts/#{account.id}", headers: { 'api_access_token' => token }
      expect(response).to have_http_status(:unauthorized)
      expect_no_store_data_on_denial(401)
    end

    it '失効 | GET /platform/api/v1/accounts/{店舗} | 店舗の許可を外した platform app の token | 401' do
      platform_app.platform_app_permissibles.find_by!(permissible: account).destroy!
      get "/platform/api/v1/accounts/#{account.id}", headers: { 'api_access_token' => static_token(:platform_app) }
      expect(response).to have_http_status(:unauthorized)
      expect_no_store_data_on_denial(401)
    end

    it '失効 | GET /toybaco/billing/access?account_id={店舗} | サインアウトしたダッシュボード cookie の再送 | 401' do
      sign_in_dashboard(users[:administrator])
      credential = cookies['cw_d_session_info']
      get "/toybaco/billing/access?account_id=#{account.id}", headers: browser_headers
      expect(response).to have_http_status(:ok)
      get '/toybaco/browser-session', headers: browser_headers
      delete '/auth/sign_out', headers: browser_headers.merge('X-CSRF-Token' => response.parsed_body.fetch('csrf_token'))
      expect(response).to have_http_status(:ok)
      cookies['cw_d_session_info'] = credential
      get "/toybaco/billing/access?account_id=#{account.id}", headers: browser_headers
      expect(response).to have_http_status(:unauthorized)
      expect_no_store_data_on_denial(401)
    end

    it '失効 | GET /super_admin/accounts/{店舗} | サインアウトした super admin の管理画面 session | 302' do
      sign_in_admin_with_mfa(users[:super_admin])
      get "/super_admin/accounts/#{account.id}"
      expect(response).to have_http_status(:ok)
      delete '/super_admin/sign_out'
      get "/super_admin/accounts/#{account.id}"
      expect(response).to have_http_status(:found)
      expect_no_store_data_on_denial(302)
    end
  end

  # TTL・MFA の方針は変えない。静的 token が期限と MFA の外にあることを、現状の観察として固定する。
  describe '観察(静的 token の期限・MFA)' do
    def enroll_mfa(user)
      user.update!(otp_secret: User.generate_otp_secret, otp_required_for_login: true, otp_backup_codes: ['MATRIX02'])
    end

    it '観察 | GET /api/v1/profile | 400 日前に発行した user 静的 token(期限の列も強制もない) | 200' do
      token = users[:agent].access_token
      token.update!(created_at: 400.days.ago, updated_at: 400.days.ago)
      expect(AccessToken.column_names.grep(/expir/)).to be_empty
      get '/api/v1/profile', headers: { 'api_access_token' => token.token }
      expect(response).to have_http_status(:ok)
    end

    it '観察 | GET /api/v1/accounts/{店舗}/conversations | MFA 登録済み administrator の静的 token | 200' do
      enroll_mfa(users[:administrator])
      get "/api/v1/accounts/#{account.id}/conversations", headers: { 'api_access_token' => static_token(:administrator) }
      expect(response).to have_http_status(:ok)
    end

    it '観察 | GET /api/v1/accounts/{店舗}/conversations | MFA 登録済み administrator の MFA 証明のない session token | 401' do
      enroll_mfa(users[:administrator])
      session_headers = users[:administrator].create_new_auth_token
      get "/api/v1/accounts/#{account.id}/conversations", headers: session_headers
      expect(response).to have_http_status(:unauthorized)
      expect_no_store_data_on_denial(401)
    end

    it '観察 | GET /super_admin | MFA 登録済み super admin の静的 token | 302' do
      get '/super_admin', headers: { 'api_access_token' => static_token(:super_admin) }
      expect(response).to have_http_status(:found)
      expect_no_store_data_on_denial(302)
    end
  end
end
