# frozen_string_literal: true

require 'rails_helper'

# CASA 6.6.1: 上流の PushNotificationService はログインの有無を見ずに保存済みの購読へ送り、sw.js は届いた通知をそのまま表示する。
# 購読は登録したログイン(DeviseTokenAuth の client)の SHA-256 で結び付け、送る直前にそのログインが今も有効か(users の行の
# tokens に残り、期限内か)を照合する。登録は保存の直前に、logout は購読を消す前に、users の行を lock して順番を揃える。
# browser の unsubscribe が時間内に終わらない・拒否されるときも、logout したログインの購読には送らない。
RSpec.describe Toybaco::Security::PushSubscriptionSession do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:endpoint) { "https://push.example.test/#{SecureRandom.hex(8)}" }

  # 同じ利用者の 2 つ目のログイン。sign_in_user_with_mfa は MFA の secret を作り直し、SessionRevocation が全ログインを失効させる。
  # ここでは使い捨ての backup code だけを足して、本当の MFA ログインをもう一度通す(backup code の変更はログインを失効させない)。
  def another_login(login_user)
    code = SecureRandom.hex(4).upcase
    login_user.update!(otp_backup_codes: [code])
    post '/auth/sign_in', params: { email: login_user.email, password: 'Password1!' }, as: :json
    post '/auth/sign_in', params: { mfa_token: response.parsed_body.fetch('mfa_token'), backup_code: code }, as: :json
    expect(response).to have_http_status(:ok)
    response.headers.slice('access-token', 'client', 'uid')
  end

  # 別の要求(logout・ほかの端末からの session の取り消し)が保存したのと同じく、users の行の tokens を書き換える。
  def change_tokens
    stored = User.find(user.id)
    tokens = stored.tokens.deep_dup
    yield tokens
    stored.update_columns(tokens: tokens) # rubocop:disable Rails/SkipsModelValidations
  end

  # 通知を 1 件送り、browser push を送った endpoint と、mobile(fcm)の中継に渡した push token を返す。
  def deliver_notification
    sent = []
    relayed = []
    allow(VapidService).to receive(:public_key).and_return('fixture-public-key')
    allow(WebPush).to receive(:payload_send) { |**payload| sent << payload[:endpoint] }
    allow(ChatwootHub).to receive(:send_push) { |options| relayed << options[:token] }
    notification = create(:notification, user: user, account: account, primary_actor: create(:conversation, account: account))
    with_modified_env(ENABLE_PUSH_RELAY_SERVER: 'true') { Notification::PushNotificationService.new(notification: notification).perform }
    [sent, relayed]
  end

  def register(headers, push_endpoint, extra = {})
    attributes = { endpoint: push_endpoint, p256dh: 'fixture-p256dh', auth: 'fixture-auth' }.merge(extra)
    post '/api/v1/notification_subscriptions',
         params: { notification_subscription: { subscription_type: 'browser_push', subscription_attributes: attributes } },
         headers: headers, as: :json
    expect(response).to have_http_status(:ok)
  end

  it 'logout はそのログインで登録した購読を server 側で消し(browser の解除が終わらなくても)、ほかのログインの購読は残す' do
    browser = sign_in_user_with_mfa(user)
    other = another_login(user)
    expect(other['client']).not_to eq(browser['client'])
    register(browser, endpoint, toybaco_session: 'forged-by-client')
    register(other, "#{endpoint}-other")
    stored = NotificationSubscription.find_by!(identifier: endpoint)
    expect(stored.subscription_attributes[described_class::SESSION_KEY]).to eq(described_class.digest(browser['client']))
    expect(stored.subscription_attributes.values).not_to include(browser['client'], 'forged-by-client')
    # browser の unsubscribe はここでは一度も呼ばれない(時間切れ・拒否と同じ)。server 側だけで消える。
    delete '/auth/sign_out', headers: browser
    expect(response).to have_http_status(:ok)
    expect(NotificationSubscription.where(user: user).pluck(:identifier)).to eq(["#{endpoint}-other"])
  end

  it '同じ browser で利用者が替わっても、前の利用者の購読は logout で消え、残った browser の購読は次の利用者のものになる' do
    next_user = create(:user, account: account)
    first = sign_in_user_with_mfa(user)
    register(first, endpoint)
    delete '/auth/sign_out', headers: first
    expect(user.notification_subscriptions.count).to eq(0)
    # browser 側の購読が残ったまま(解除が終わらなかった)次の利用者が起動し、上流の App.vue がそれを登録し直す。
    second = sign_in_user_with_mfa(next_user)
    register(second, endpoint)
    expect(NotificationSubscription.where(identifier: endpoint).pluck(:user_id)).to eq([next_user.id])
    expect(NotificationSubscription.find_by!(identifier: endpoint).subscription_attributes[described_class::SESSION_KEY])
      .to eq(described_class.digest(second['client']))
    expect(user.notification_subscriptions.count).to eq(0)
  end

  it 'mobile の購読(fcm)には印を付けず、browser の logout でも消さない' do
    headers = sign_in_user_with_mfa(user)
    post '/api/v1/notification_subscriptions',
         params: { notification_subscription: { subscription_type: 'fcm', subscription_attributes: { device_id: 'fixture-device',
                                                                                                     push_token: 'fixture-push' } } },
         headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    delete '/auth/sign_out', headers: headers
    expect(NotificationSubscription.where(user: user).pluck(:identifier, :subscription_type)).to eq([%w[fixture-device fcm]])
  end

  it '送る直前に、結び付いたログインが今も有効な購読にだけ送る(この版より前の購読・期限切れ・取り消し済みには送らず、mobile は今のまま)' do
    logins = { 'live' => sign_in_user_with_mfa(user) }
    logins['expired'] = another_login(user)
    logins['revoked'] = another_login(user)
    logins.each { |name, headers| register(headers, "#{endpoint}-#{name}") }
    create(:notification_subscription, user: user, identifier: "#{endpoint}-legacy",
                                       subscription_attributes: { endpoint: "#{endpoint}-legacy", p256dh: 'fixture-p256dh', auth: 'fixture-auth' })
    create(:notification_subscription, :fcm, user: user, identifier: 'fixture-device',
                                             subscription_attributes: { device_id: 'fixture-device', push_token: 'fixture-push' })
    change_tokens do |tokens|
      tokens[logins['expired']['client']]['expiry'] = 1.minute.ago.to_i
      tokens.delete(logins['revoked']['client'])
    end
    expect(deliver_notification).to eq([["#{endpoint}-live"], ['fixture-push']])
    # 送らない購読も消さない(この版より前の購読は、次に dashboard を開いたときの登録し直しで結び付く)。
    expect(NotificationSubscription.where(user: user).count).to eq(5)
  end

  it '登録と logout が競合し、保存の直前にそのログインが終わっていたら、購読を保存せず 401 を返す' do
    headers = sign_in_user_with_mfa(user)
    allow(NotificationSubscriptionBuilder).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      # 認証の後・保存の前に、同じログインの logout が確定した(users の行の tokens からこのログインが消えた)。
      change_tokens { |tokens| tokens.delete(headers['client']) }
      original.call(*args, **kwargs)
    end
    post '/api/v1/notification_subscriptions',
         params: { notification_subscription: { subscription_type: 'browser_push',
                                                subscription_attributes: { endpoint: endpoint, p256dh: 'fixture-p256dh', auth: 'fixture-auth' } } },
         headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(NotificationSubscription.where(identifier: endpoint)).not_to exist
  end

  it '登録の保存と logout の購読の削除は、どちらも users の行を lock してから行う(並んだ要求の順番が揃う)' do
    headers = sign_in_user_with_mfa(user)
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      register(headers, endpoint)
      delete '/auth/sign_out', headers: headers
    end
    expect(response).to have_http_status(:ok)
    insert = statements.index { |sql| sql.start_with?('INSERT INTO "notification_subscriptions"') }
    removal = statements.index { |sql| sql.start_with?('DELETE FROM "notification_subscriptions"') }
    user_lock = /\ASELECT "users"\.\* FROM "users" WHERE "users"\."id" = .*FOR UPDATE\z/m
    locks = statements.each_index.select { |index| statements[index].match?(user_lock) }
    expect([insert, removal]).to all(be_a(Integer))
    expect([locks.count { |index| index < insert }, locks.count { |index| index > insert && index < removal }]).to all(be >= 1)
  end

  it '期限の切れたログインの logout(404)では購読が残るが、送信の照合で送らない' do
    headers = sign_in_user_with_mfa(user)
    register(headers, endpoint)
    change_tokens { |tokens| tokens[headers['client']]['expiry'] = 1.minute.ago.to_i }
    delete '/auth/sign_out', headers: headers
    expect(response).to have_http_status(:not_found)
    expect(NotificationSubscription.where(identifier: endpoint)).to exist
    expect(deliver_notification).to eq([[], []])
  end

  it 'MFA proof の期限直前は届き、期限直後は DTA が有効で logout が404でも届かない' do
    with_modified_env(TOYBACO_APPLICATION_MFA_MAX_AGE_HOURS: nil) do
      headers = sign_in_user_with_mfa(user)
      register(headers, endpoint)
      proof_at = user.reload.tokens.fetch(headers['client']).fetch('toybaco_mfa_at')
      expires_at = Time.zone.at(proof_at) + Toybaco::Security::ApplicationMfaSession.max_age
      travel_to(expires_at - 1.second) { expect(deliver_notification).to eq([[endpoint], []]) }
      travel_to(expires_at + 1.second) do
        expect(user.reload.tokens.fetch(headers['client']).fetch('expiry').to_i).to be > Time.current.to_i
        delete '/auth/sign_out', headers: headers
        expect(response).to have_http_status(:not_found)
        expect(NotificationSubscription.where(identifier: endpoint)).to exist
        expect(deliver_notification).to eq([[], []])
      end
    end
  end

  context 'when a login or logout committed on another connection overlaps(別接続で commit する login / logout と重なるとき)' do
    self.use_transactional_tests = false

    # この context だけ commit が必要。作った account / user とその従属レコードだけを後始末する。
    let!(:account) { create(:account) }
    let!(:user) { create(:user, account: account) }

    after do
      perform_enqueued_jobs(only: ActiveRecord::DestroyAssociationAsyncJob) do
        # 会話・contact・inbox の削除の callback は account を読むので、account より先に消す。
        [account.conversations, account.contacts, account.inboxes].each(&:destroy_all)
        account.destroy!
        user.destroy!
      end
      clear_enqueued_jobs
      Current.reset
    end

    def another_connection(&)
      thread = Thread.new { User.connection_pool.with_connection(&) }
      raise 'concurrent fixture timed out' unless thread.join(15)

      thread.value
    ensure
      thread&.kill if thread&.alive?
      thread&.join
    end

    def independent_login
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.post '/auth/sign_in', params: { email: user.email, password: 'Password1!' }, as: :json
      expect(session.response).to have_http_status(:ok)
      session.response.headers.slice('access-token', 'client', 'uid')
    end

    def independent_logout(headers)
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.delete '/auth/sign_out', headers: headers
      expect(session.response).to have_http_status(:ok)
    end

    # destroy の before_action は完了済み、Revocation の lock はまだ。古い @resource を確実に残してから、
    # 別接続の要求を最後まで完了させる。sleep や thread の実行速度には依存しない。
    def before_logout_lock(client, &)
      allow(DeviseOverrides::SessionsController).to receive(:new).and_wrap_original do |constructor, *args|
        controller = constructor.call(*args)
        allow(controller).to receive(:destroy).and_wrap_original do |original, *action_args|
          if controller.instance_variable_get(:@token)&.client == client
            expect(controller.instance_variable_get(:@resource)).to be_a(User)
            another_connection(&)
          end
          original.call(*action_args)
        end
        controller
      end
    end

    it 'query cache が有効な同じ job の二つの配送間で logout が commit したら二つ目を送らない' do
      headers = independent_login
      register(headers, endpoint)
      register(headers, "#{endpoint}-second")
      notification = create(:notification, user: user, account: account, primary_actor: create(:conversation, account: account))
      sent = []
      logout_completed = false
      allow(VapidService).to receive(:public_key).and_return('fixture-public-key')
      allow(WebPush).to receive(:payload_send) do |**payload|
        sent << payload[:endpoint]
        if sent.size == 1
          expect(User.connection.query_cache_enabled).to be(true)
          another_connection { independent_logout(headers) }
          logout_completed = true
        end
      end
      User.cache { Notification::PushNotificationJob.perform_now(notification) }
      expect(logout_completed).to be(true)
      expect(sent.size).to eq(1)
      expect([endpoint, "#{endpoint}-second"]).to include(sent.first)
      expect(user.reload.tokens).to be_empty
    end

    it 'logout の認証後に commit した別の login を古い tokens で消さない' do
      first = independent_login
      register(first, endpoint)
      second = nil
      before_logout_lock(first['client']) { second = independent_login }

      delete '/auth/sign_out', headers: first

      expect(response).to have_http_status(:ok)
      expect(user.reload.tokens.keys).to eq([second.fetch('client')])
      expect(user.valid_token?(second['access-token'], second['client'])).to be(true)
      expect(NotificationSubscription.where(identifier: endpoint)).not_to exist
    end

    it '二つの client の logout が古い同じ tokens を読んでも、先に消した client を復活させない' do
      first = independent_login
      second = independent_login
      register(first, endpoint)
      register(second, "#{endpoint}-second")
      before_logout_lock(second['client']) { independent_logout(first) }

      delete '/auth/sign_out', headers: second

      expect(response).to have_http_status(:ok)
      expect(user.reload.tokens).to be_empty
      expect(user.notification_subscriptions).to be_empty
      expect(user.valid_token?(first['access-token'], first['client'])).to be(false)
      expect(user.valid_token?(second['access-token'], second['client'])).to be(false)
    end
  end
end
