# frozen_string_literal: true

require 'rails_helper'
require 'stringio'

# Instagram の 60 日 token の更新(CW-5、4 時間ごと)。更新の API(graph.instagram.com/refresh_access_token)は WebMock で返す。
# 店舗の管理者への通知(S-D): expired は上流の instagram_disconnect(enqueue を見る)、expiring は店舗の管理者宛ての
# Toybaco::ChannelNoticeMailer(配送を test に替えて見る)。ほかの状態・orphan・停止中の店舗・停止の設定では知らせない。
# 店舗の管理者へのメールは TOYBACO_CHANNEL_NOTICE_EMAILS が on の時だけ送る(Toybaco::ChannelNoticeEmails。既定は off)。
RSpec.describe Toybaco::InstagramTokenRefreshJob do
  let(:log) { StringIO.new }
  let(:logger) do
    Logger.new(log, level: :info).tap { |value| value.formatter = proc { |severity, _time, _program, message| "#{severity} #{message}\n" } }
  end
  let(:now) { Time.zone.parse('2026-10-20 04:25:00') }
  let(:account) { create(:account) }
  let(:refresh_url) { 'https://graph.instagram.com/refresh_access_token' }
  let(:mailer) { AdministratorNotifications::ChannelNotificationsMailer }
  let(:admin) { create(:user, account: account, role: :administrator, email: 'ig-admin@example.invalid') }
  let(:agent) { create(:user, account: account, role: :agent, email: 'ig-agent@example.invalid') }

  # 上流の config/initializers/mailer.rb は SMTP_ADDRESS の無い環境を sendmail にするので、配送だけ test に替える(ops_digest_spec と同じ)。
  around do |example|
    original = [ActionMailer::Base.delivery_method, ActionMailer::Base.perform_deliveries]
    ActionMailer::Base.delivery_method = :test
    ActionMailer::Base.perform_deliveries = true
    example.run
  ensure
    ActionMailer::Base.delivery_method, ActionMailer::Base.perform_deliveries = original
  end

  # 既存の例は on で流す。off は channel_notice_emails: で値(nil は未設定)を替えた例で見る。env は例の後に元へ戻る。
  around do |example|
    with_modified_env('TOYBACO_CHANNEL_NOTICE_EMAILS' => example.metadata.fetch(:channel_notice_emails, 'on')) { example.run }
  end

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    admin
    agent
    ActionMailer::Base.deliveries.clear
    stub_request(:get, refresh_url).with(query: hash_including('grant_type' => 'ig_refresh_token'))
                                   .to_return(status: 200, body: { access_token: 'refreshed-token-value', expires_in: 5_184_000 }.to_json,
                                              headers: { 'Content-Type' => 'application/json' })
  end

  def instagram(expires_in:, updated_ago: 2 * 86_400)
    travel_to(now) do
      channel = create(:channel_instagram, account: account, access_token: "ig-token-#{SecureRandom.hex(16)}")
      channel.update_columns(expires_at: now + expires_in, updated_at: now - updated_ago) # rubocop:disable Rails/SkipsModelValidations
      Redis::Alfred.delete("TOYBACO_INSTAGRAM_TOKEN_NOTICE::#{channel.id}")
      Redis::Alfred.delete(format(Redis::Alfred::REAUTHORIZATION_REQUIRED, obj_type: 'channel_instagram', obj_id: channel.id))
      channel
    end
  end

  def run_job
    travel_to(now) { described_class.perform_now }
  end

  def line_for(channel)
    log.string.lines.grep(/TOYBACO_INSTAGRAM_TOKEN status=\S+ inbox=#{channel.inbox.id} /)
  end

  def refresh_request
    a_request(:get, refresh_url).with(query: hash_including({}))
  end

  def run_at(hours)
    travel_to(now + (hours * 3600)) { described_class.perform_now }
  end

  def notice_failures
    log.string.lines.grep(/TOYBACO_CHANNEL_NOTICE_FAILED/)
  end

  def run_at_utc(time)
    travel_to(time) { described_class.perform_now }
  end

  def notice_stamp(channel)
    Redis::Alfred.get("TOYBACO_INSTAGRAM_TOKEN_NOTICE::#{channel.id}")
  end

  def reauthorization_key(channel)
    format(Redis::Alfred::REAUTHORIZATION_REQUIRED, obj_type: 'channel_instagram', obj_id: channel.id)
  end

  # 上流の prompt_reauthorization! が出す event(画面の再認証の表示の更新の元)を、名前と受信箱の変化の組で集める。
  # 受信箱の更新の event は ENABLE_INBOX_EVENTS がある時だけ出るので、その env を付けて流す。
  # 集めるのは block の間だけ(stub は block の後も残るので、後で受信箱を作った時の cache の無効化の event を入れない)。
  def dispatched_events(&)
    events = []
    recording = true
    allow(Rails.configuration.dispatcher).to receive(:dispatch) { |name, _time, data| events << [name, data[:changed_attributes]] if recording }
    with_modified_env('ENABLE_INBOX_EVENTS' => 'true', &)
    events
  ensure
    recording = false
  end

  it '更新の時期(期限 10 日前以内)なら上流の経路で更新し、refreshed を出して期限を 60 日延ばす。token の値は行に出さない' do
    channel = instagram(expires_in: 9 * 86_400)
    token = channel.reload[:access_token]

    clear_enqueued_jobs
    run_job
    # 積まれるのは上流の更新(channel の update!)が出す受信箱の cache の無効化とその配信だけで、メールは積まない。
    expect(enqueued_jobs.pluck(:job).uniq - [EventDispatcherJob, ActionCableBroadcastJob]).to be_empty
    expect(line_for(channel)).to eq(["INFO TOYBACO_INSTAGRAM_TOKEN status=refreshed inbox=#{channel.inbox.id} days_left=60\n"])
    expect(channel.reload.expires_at).to be_within(5).of(now + 5_184_000)
    expect(channel[:access_token]).to eq('refreshed-token-value')
    expect(refresh_request).to have_been_made.once
    expect(log.string).not_to include(token, 'refreshed-token-value')
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it '何度走っても同じ結果になる(同じ日の 2 回目は更新の条件を満たさず、API を呼ばない)' do
    channel = instagram(expires_in: 9 * 86_400)

    2.times { run_job }
    expect(line_for(channel)).to eq(["INFO TOYBACO_INSTAGRAM_TOKEN status=refreshed inbox=#{channel.inbox.id} days_left=60\n",
                                     "INFO TOYBACO_INSTAGRAM_TOKEN status=valid inbox=#{channel.inbox.id} days_left=60\n"])
    expect(refresh_request).to have_been_made.once
  end

  it '更新の時期でなければ API を呼ばず、valid を出す' do
    channel = instagram(expires_in: 40 * 86_400)

    run_job
    expect(line_for(channel)).to eq(["INFO TOYBACO_INSTAGRAM_TOKEN status=valid inbox=#{channel.inbox.id} days_left=40\n"])
    expect(refresh_request).not_to have_been_made
  end

  it '更新の時期なのに更新に失敗したら failed を出す(通知しない)' do
    stub_request(:get, refresh_url).with(query: hash_including({})).to_return(status: 400, body: '{"error":"secret detail"}')
    channel = instagram(expires_in: (8 * 86_400) + 3600)

    expect { run_job }.not_to have_enqueued_job
    expect(line_for(channel)).to eq(["WARN TOYBACO_INSTAGRAM_TOKEN status=failed inbox=#{channel.inbox.id} days_left=8\n"])
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it '1 件の例外は failed と例外の class だけを出し、残りの受信箱は確かめ続ける' do
    broken = instagram(expires_in: 40 * 86_400)
    healthy = instagram(expires_in: 40 * 86_400)
    allow(Instagram::RefreshOauthTokenService).to receive(:new).and_wrap_original do |original, channel:|
      raise ActiveRecord::StatementInvalid, 'secret detail' if channel.id == broken.id

      original.call(channel: channel)
    end

    run_job
    expect(line_for(broken))
      .to eq(["WARN TOYBACO_INSTAGRAM_TOKEN status=failed inbox=#{broken.inbox.id} days_left=40 error=ActiveRecord::StatementInvalid\n"])
    expect(line_for(healthy)).to eq(["INFO TOYBACO_INSTAGRAM_TOKEN status=valid inbox=#{healthy.inbox.id} days_left=40\n"])
    expect(log.string).not_to include('secret detail')
  end

  it '店舗(account)が無い受信箱は orphan を出して飛ばし、後に続く受信箱は更新する' do
    orphan = instagram(expires_in: 9 * 86_400)
    orphan.update_columns(account_id: 0) # rubocop:disable Rails/SkipsModelValidations
    healthy = instagram(expires_in: 9 * 86_400)

    run_job
    expect(line_for(orphan)).to eq(["WARN TOYBACO_INSTAGRAM_TOKEN status=orphan inbox=#{orphan.inbox.id} days_left=9\n"])
    expect(line_for(healthy)).to eq(["INFO TOYBACO_INSTAGRAM_TOKEN status=refreshed inbox=#{healthy.inbox.id} days_left=60\n"])
    expect(healthy.reload.expires_at).to be_within(5).of(now + 5_184_000)
    expect(orphan.reload.expires_at).to be_within(1).of(now + (9 * 86_400))
    expect(refresh_request).to have_been_made.once
  end

  it 'API の更新が成功しても上流の保存が失敗したら、DB から読み直した期限で failed にし、refreshed にしない' do
    target = instagram(expires_in: 9 * 86_400)
    allow(Instagram::RefreshOauthTokenService).to receive(:new).and_wrap_original do |original, channel:|
      # 上流の update! は属性を入れてから save! するので、memory の expires_at だけが新しくなる。
      allow(channel).to receive(:save!).and_raise(ActiveRecord::StatementInvalid, 'secret detail')
      original.call(channel: channel)
    end

    run_job
    expect(line_for(target)).to eq(["WARN TOYBACO_INSTAGRAM_TOKEN status=failed inbox=#{target.inbox.id} days_left=9\n"])
    expect(target.reload.expires_at).to be_within(1).of(now + (9 * 86_400))
    expect(refresh_request).to have_been_made.once
    expect(log.string).not_to include('refreshed-token-value')
  end

  it '更新APIの失敗本文にtokenが含まれてもログへ出さない' do
    channel = instagram(expires_in: 9 * 86_400)
    token = channel.reload[:access_token]
    detail = 'synthetic-instagram-response-secret'
    stub_request(:get, refresh_url).with(query: hash_including({}))
                                   .to_return(status: 400, body: { error: { message: "#{detail} #{token}" } }.to_json)

    run_job
    expect(line_for(channel)).to eq(["WARN TOYBACO_INSTAGRAM_TOKEN status=failed inbox=#{channel.inbox.id} days_left=9\n"])
    expect(log.string).not_to include(detail, token)
    expect(log.string).to include('status=400', 'error=RuntimeError')
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it '更新APIの不正JSON本文にtokenが含まれてもparse例外からログへ出さない' do
    channel = instagram(expires_in: 9 * 86_400)
    token = channel.reload[:access_token]
    detail = 'synthetic-instagram-json-secret'
    stub_request(:get, refresh_url).with(query: hash_including({})).to_return(status: 200, body: "{invalid #{detail} #{token}")

    run_job
    expect(line_for(channel)).to eq(["WARN TOYBACO_INSTAGRAM_TOKEN status=failed inbox=#{channel.inbox.id} days_left=9\n"])
    expect(log.string).not_to include(detail, token)
    expect(log.string).to include('error=JSON::ParserError')
  end

  it '更新API成功後の保存例外にtokenが含まれてもログへ出さずDBの期限で判定する' do
    target = instagram(expires_in: 9 * 86_400)
    token = target.reload[:access_token]
    detail = 'synthetic-instagram-save-secret'
    allow(Instagram::RefreshOauthTokenService).to receive(:new).and_wrap_original do |original, channel:|
      allow(channel).to receive(:save!).and_raise(ActiveRecord::StatementInvalid, "#{detail} #{token} refreshed-token-value")
      original.call(channel: channel)
    end

    run_job
    expect(line_for(target)).to eq(["WARN TOYBACO_INSTAGRAM_TOKEN status=failed inbox=#{target.inbox.id} days_left=9\n"])
    expect(target.reload.expires_at).to be_within(1).of(now + (9 * 86_400))
    expect(log.string).not_to include(detail, token, 'refreshed-token-value')
    expect(log.string).to include('error=ActiveRecord::StatementInvalid')
  end

  it '4 時間ごとに走っても、更新できた後の 24 時間は API を呼ばない。更新に失敗した時は次の回でやり直す' do
    channel = instagram(expires_in: 9 * 86_400)
    stub_request(:get, refresh_url).with(query: hash_including({}))
                                   .to_return({ status: 500, body: '' },
                                              { status: 200, body: { access_token: 'refreshed-token-value', expires_in: 5_184_000 }.to_json,
                                                headers: { 'Content-Type' => 'application/json' } })

    [0, 4, 8, 12].each { |hours| travel_to(now + (hours * 3600)) { described_class.perform_now } }
    expect(line_for(channel).map { |line| line[/status=\w+/] }).to eq(%w[status=failed status=refreshed status=valid status=valid])
    expect(refresh_request).to have_been_made.twice
  end

  it 'rescue の中で inbox を読めなくても(DB の障害)、最初に取った id で失敗の行を出し、後に続く受信箱を処理する' do
    broken = instagram(expires_in: 9 * 86_400)
    healthy = instagram(expires_in: 9 * 86_400)
    broken_inbox_id = broken.inbox.id
    allow(Instagram::RefreshOauthTokenService).to receive(:new).and_wrap_original do |original, channel:|
      if channel.id == broken.id
        # reload で association の cache が消え、DB が落ちた後に inbox を読むと例外になる状態を作る。
        allow(channel).to receive(:reload) do
          allow(channel).to receive(:inbox).and_raise(ActiveRecord::ConnectionNotEstablished, 'db down')
          raise ActiveRecord::ConnectionNotEstablished, 'db down'
        end
      end
      original.call(channel: channel)
    end

    run_job
    expect(log.string.lines.grep(/inbox=#{broken_inbox_id} /))
      .to eq(["WARN TOYBACO_INSTAGRAM_TOKEN status=failed inbox=#{broken_inbox_id} days_left=9 error=ActiveRecord::ConnectionNotEstablished\n"])
    expect(line_for(healthy)).to eq(["INFO TOYBACO_INSTAGRAM_TOKEN status=refreshed inbox=#{healthy.inbox.id} days_left=60\n"])
  end

  it '停止中の店舗の受信箱は確かめない(期限切れでも知らせない)' do
    channel = instagram(expires_in: 9 * 86_400)
    expired = instagram(expires_in: -1 * 86_400)
    account.update_columns(status: :suspended) # rubocop:disable Rails/SkipsModelValidations

    expect { run_job }.not_to have_enqueued_mail(mailer, :instagram_disconnect)
    expect(line_for(channel) + line_for(expired)).to be_empty
    expect(refresh_request).not_to have_been_made
    expect(expired.reauthorization_required?).to be(false)
  end

  it 'TOYBACO_INSTAGRAM_TOKEN_REFRESH=off なら、DB の走査も API の呼び出しもせず、disabled の行だけを出して正常に終わる' do
    channel = instagram(expires_in: 9 * 86_400)
    allow(Channel::Instagram).to receive(:includes).and_call_original

    with_modified_env('TOYBACO_INSTAGRAM_TOKEN_REFRESH' => 'off') { expect { run_job }.not_to raise_error }
    expect(Channel::Instagram).not_to have_received(:includes)
    expect(refresh_request).not_to have_been_made
    expect(channel.reload.expires_at).to be_within(1).of(now + (9 * 86_400))
    expect(log.string.lines).to eq(["INFO TOYBACO_INSTAGRAM_TOKEN status=disabled\n"])
  end

  it 'off のとき、cron が消える前に積まれていた同じ class の job(queued)も、API を呼ばずに正常に終わる' do
    channel = instagram(expires_in: 9 * 86_400)
    clear_enqueued_jobs
    travel_to(now) { described_class.perform_later }

    with_modified_env('TOYBACO_INSTAGRAM_TOKEN_REFRESH' => 'off') { travel_to(now) { perform_enqueued_jobs } }
    expect(enqueued_jobs).to be_empty
    expect(refresh_request).not_to have_been_made
    expect(channel.reload.expires_at).to be_within(1).of(now + (9 * 86_400))
  end

  it 'off 以外の値(on)では、今のまま上流の経路で更新する' do
    channel = instagram(expires_in: 9 * 86_400)

    with_modified_env('TOYBACO_INSTAGRAM_TOKEN_REFRESH' => 'on') { run_job }
    expect(refresh_request).to have_been_made.once
    expect(line_for(channel)).to eq(["INFO TOYBACO_INSTAGRAM_TOKEN status=refreshed inbox=#{channel.inbox.id} days_left=60\n"])
  end

  it 'scheduled_jobs に載り、引数を取らない' do
    expect(described_class.new.queue_name).to eq('scheduled_jobs')
    expect(described_class.instance_method(:perform).arity).to eq(0)
  end

  # 店舗の管理者への通知(time-bomb 調査の S-D)。判定と通知は DB から読み直した値で行う。
  context 'with the notices to the store administrators' do
    it '期限まで 7 日以内で更新できなければ expiring を出し、フラグを立てず上流の instagram_disconnect も送らず、日本語の案内を期限ごとに 1 回だけ送る(4 時間ごとに走っても同じ)' do
      stub_request(:get, refresh_url).with(query: hash_including({})).to_return(status: 500, body: '')
      channel = instagram(expires_in: 6 * 86_400)
      allow(Toybaco::ChannelNoticeMailer).to receive(:with).and_call_original

      expect { [0, 4, 8].each { |hours| run_at(hours) } }.not_to have_enqueued_mail(mailer, :instagram_disconnect)
      expect(line_for(channel))
        .to eq([6, 5, 5].map { |days| "WARN TOYBACO_INSTAGRAM_TOKEN status=expiring inbox=#{channel.inbox.id} days_left=#{days}\n" })
      expect(channel.reauthorization_required?).to be(false)
      expect(Toybaco::ChannelNoticeMailer).to have_received(:with).once
      expect(ActionMailer::Base.deliveries.size).to eq(1)
      expect(Redis::Alfred.get("TOYBACO_INSTAGRAM_TOKEN_NOTICE::#{channel.id}")).to eq(channel.reload.expires_at.to_i.to_s)
    end

    it 'expiring の案内は店舗の管理者だけに送り、Cc・Bcc は付けない' do
      stub_request(:get, refresh_url).with(query: hash_including({})).to_return(status: 500, body: '')
      channel = instagram(expires_in: 6 * 86_400)

      run_job
      mail = ActionMailer::Base.deliveries.sole
      expect([mail.to, mail.cc, mail.bcc]).to eq([['ig-admin@example.invalid'], nil, nil])
      expect(mail.subject).to eq("【トイバコ】Instagram の接続の期限が近づいています(#{channel.inbox.name})")
      expect(mail.decoded).to include("Instagram の受信箱「#{channel.inbox.name}」の接続は、あと 6 日ほどで期限が切れます。")
      expect(mail.decoded).to include('「設定」→「受信箱」→「受信箱を追加」を開き、Instagram を選びます。')
      expect(mail.decoded).to include("/app/accounts/#{account.id}/settings/inboxes/#{channel.inbox.id}")
      expect(mail.decoded).to include('このメールは、トイバコが定期的に行う接続の確認から自動でお送りしています。')
      expect(mail.decoded).not_to include('has expired', '毎日')
    end

    it '失効していたら expired を出し、上流の prompt_reauthorization! で 1 回だけ知らせる(4 時間ごとに走っても同じ。API は呼ばない)' do
      channel = instagram(expires_in: -2 * 86_400)

      expect { run_job }.to have_enqueued_mail(mailer, :instagram_disconnect).once
      expect(channel.reauthorization_required?).to be(true)
      expect { run_at(4) }.not_to have_enqueued_mail(mailer, :instagram_disconnect)
      expect(line_for(channel))
        .to eq([-2, -3].map { |days| "WARN TOYBACO_INSTAGRAM_TOKEN status=expired inbox=#{channel.inbox.id} days_left=#{days}\n" })
      expect(refresh_request).not_to have_been_made
      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it 'API の更新が成功しても上流の保存が失敗したら、DB から読み直した期限で expiring にし、その期限で案内を送る' do
      target = instagram(expires_in: 6 * 86_400)
      allow(Instagram::RefreshOauthTokenService).to receive(:new).and_wrap_original do |original, channel:|
        allow(channel).to receive(:save!).and_raise(ActiveRecord::StatementInvalid, 'secret detail')
        original.call(channel: channel)
      end

      run_job
      expect(refresh_request).to have_been_made.once
      expect(line_for(target)).to eq(["WARN TOYBACO_INSTAGRAM_TOKEN status=expiring inbox=#{target.inbox.id} days_left=6\n"])
      expect(ActionMailer::Base.deliveries.sole.decoded).to include('あと 6 日ほどで期限が切れます。')
      expect(Redis::Alfred.get("TOYBACO_INSTAGRAM_TOKEN_NOTICE::#{target.id}")).to eq(target.reload.expires_at.to_i.to_s)
    end

    it '案内を送れなかったら TOYBACO_CHANNEL_NOTICE_FAILED の 1 行だけを出し(宛先・例外の message は出さない)、状態の行は変えず、次の回で送り直す' do
      stub_request(:get, refresh_url).with(query: hash_including({})).to_return(status: 500, body: '')
      channel = instagram(expires_in: 6 * 86_400)
      calls = 0
      allow(Toybaco::ChannelNoticeMailer).to receive(:with).and_wrap_original do |original, *args, **params|
        calls += 1
        raise Errno::ECONNREFUSED, 'smtp.example.invalid ig-admin@example.invalid' if calls == 1

        original.call(*args, **params)
      end

      run_job
      expect(notice_failures).to eq(["ERROR TOYBACO_CHANNEL_NOTICE_FAILED provider=instagram inbox=#{channel.inbox.id} class=Errno::ECONNREFUSED\n"])
      expect(line_for(channel)).to eq(["WARN TOYBACO_INSTAGRAM_TOKEN status=expiring inbox=#{channel.inbox.id} days_left=6\n"])
      expect(log.string).not_to include('ig-admin@example.invalid', 'smtp.example.invalid')
      expect(ActionMailer::Base.deliveries).to be_empty

      run_at(4)
      expect(ActionMailer::Base.deliveries.map(&:to)).to eq([['ig-admin@example.invalid']])
      expect(notice_failures.size).to eq(1)
    end

    it '再認証の通知に失敗しても TOYBACO_CHANNEL_NOTICE_FAILED の 1 行だけを出し、ほかの受信箱は確かめ続ける' do
      broken = instagram(expires_in: -2 * 86_400)
      healthy = instagram(expires_in: 9 * 86_400)
      allow(Instagram::RefreshOauthTokenService).to receive(:new).and_wrap_original do |original, channel:|
        allow(channel).to receive(:prompt_reauthorization!).and_raise(Redis::CannotConnectError, 'secret detail') if channel.id == broken.id
        original.call(channel: channel)
      end

      run_job
      expect(notice_failures)
        .to eq(["ERROR TOYBACO_CHANNEL_NOTICE_FAILED provider=instagram inbox=#{broken.inbox.id} class=Redis::CannotConnectError\n"])
      expect(line_for(broken)).to eq(["WARN TOYBACO_INSTAGRAM_TOKEN status=expired inbox=#{broken.inbox.id} days_left=-2\n"])
      expect(line_for(healthy)).to eq(["INFO TOYBACO_INSTAGRAM_TOKEN status=refreshed inbox=#{healthy.inbox.id} days_left=60\n"])
      expect(log.string).not_to include('secret detail')
    end

    it '店舗(account)が無い受信箱は、期限切れでも orphan を出すだけで知らせない' do
      orphan = instagram(expires_in: -2 * 86_400)
      orphan.update_columns(account_id: 0) # rubocop:disable Rails/SkipsModelValidations

      expect { run_job }.not_to have_enqueued_mail(mailer, :instagram_disconnect)
      expect(line_for(orphan)).to eq(["WARN TOYBACO_INSTAGRAM_TOKEN status=orphan inbox=#{orphan.inbox.id} days_left=-2\n"])
      expect(orphan.reauthorization_required?).to be(false)
      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it '停止の設定(TOYBACO_INSTAGRAM_TOKEN_REFRESH=off)の時は、期限切れ・期限間近でも知らせない' do
      expired = instagram(expires_in: -2 * 86_400)
      instagram(expires_in: 6 * 86_400)

      with_modified_env('TOYBACO_INSTAGRAM_TOKEN_REFRESH' => 'off') do
        expect { run_job }.not_to have_enqueued_mail(mailer, :instagram_disconnect)
      end
      expect(expired.reauthorization_required?).to be(false)
      expect(ActionMailer::Base.deliveries).to be_empty
      expect(log.string.lines).to eq(["INFO TOYBACO_INSTAGRAM_TOKEN status=disabled\n"])
    end

    # expiring の案内は日本時間 9 時以上 18 時未満の回(9:25・13:25・17:25 JST = 0:25・4:25・8:25 UTC)にだけ送る。
    it '日本時間の対象の外の回(01:25 JST)では案内を送らず印も書かず、状態の行は出し、次の対象の回(09:25 JST)で送る' do
      stub_request(:get, refresh_url).with(query: hash_including({})).to_return(status: 500, body: '')
      channel = instagram(expires_in: 6 * 86_400)

      run_at_utc(Time.utc(2026, 10, 20, 16, 25))
      expect(ActionMailer::Base.deliveries).to be_empty
      expect(notice_stamp(channel)).to be_nil
      run_at_utc(Time.utc(2026, 10, 21, 0, 25))
      expect(line_for(channel)).to eq(["WARN TOYBACO_INSTAGRAM_TOKEN status=expiring inbox=#{channel.inbox.id} days_left=5\n"] * 2)
      expect(ActionMailer::Base.deliveries.map(&:to)).to eq([['ig-admin@example.invalid']])
      expect(notice_stamp(channel)).to eq(channel.reload.expires_at.to_i.to_s)
    end

    it '日本時間の境目: 08:59 は送らず 09:00 は送り、17:59 は送り 18:00 は送らない(ENV の TZ と Time.zone に依らない)' do
      stub_request(:get, refresh_url).with(query: hash_including({})).to_return(status: 500, body: '')
      channel = instagram(expires_in: 6 * 86_400)
      boundaries = [Time.utc(2026, 10, 20, 23, 59), Time.utc(2026, 10, 21, 0, 0), Time.utc(2026, 10, 21, 8, 59), Time.utc(2026, 10, 21, 9, 0)]

      sent = [%w[UTC UTC], %w[Asia/Tokyo Asia/Tokyo]].map do |tz, zone|
        with_modified_env('TZ' => tz) do
          Time.use_zone(zone) do
            boundaries.map do |time|
              Redis::Alfred.delete("TOYBACO_INSTAGRAM_TOKEN_NOTICE::#{channel.id}")
              ActionMailer::Base.deliveries.clear
              run_at_utc(time)
              ActionMailer::Base.deliveries.size
            end
          end
        end
      end
      expect(sent).to eq([[0, 1, 1, 0], [0, 1, 1, 0]])
      expect(line_for(channel).size).to eq(8)
    end

    it '失効(expired)の再認証の通知は、日本時間の対象の外の回(01:25 JST)でも prompt_reauthorization! で出す' do
      channel = instagram(expires_in: -2 * 86_400)

      expect { run_at_utc(Time.utc(2026, 10, 20, 16, 25)) }.to have_enqueued_mail(mailer, :instagram_disconnect).once
      expect(channel.reauthorization_required?).to be(true)
      expect(line_for(channel)).to eq(["WARN TOYBACO_INSTAGRAM_TOKEN status=expired inbox=#{channel.inbox.id} days_left=-3\n"])
    end
  end

  context 'when TOYBACO_CHANNEL_NOTICE_EMAILS is not on' do
    let(:inbox_reauthorized) do
      [[Events::Types::ACCOUNT_CACHE_INVALIDATED, nil], [Events::Types::INBOX_UPDATED, { reauthorization_required: [false, true] }]]
    end
    # 走らせる回(now からの時間)と、その回の行の days_left。
    let(:expiring_runs) { { 0 => 6, 4 => 5, 8 => 5 } }
    let(:expired_runs) { { 0 => -2, 4 => -3 } }

    [nil, 'off'].each do |value|
      it "期限まで 7 日以内でも案内を送らず、送信済みの印も書かず、4 時間ごとの次の回でも送らない。行はそのまま(#{value.inspect})",
         channel_notice_emails: value do
        stub_request(:get, refresh_url).with(query: hash_including({})).to_return(status: 500, body: '')
        channel = instagram(expires_in: 6 * 86_400)
        allow(Toybaco::ChannelNoticeMailer).to receive(:with).and_call_original

        expect { expiring_runs.each_key { |hours| run_at(hours) } }.not_to have_enqueued_mail(mailer, :instagram_disconnect)
        expect(line_for(channel))
          .to eq(expiring_runs.values.map { |days| "WARN TOYBACO_INSTAGRAM_TOKEN status=expiring inbox=#{channel.inbox.id} days_left=#{days}\n" })
        expect(Toybaco::ChannelNoticeMailer).not_to have_received(:with)
        expect(ActionMailer::Base.deliveries).to be_empty
        expect(notice_stamp(channel)).to be_nil
        expect(channel.reauthorization_required?).to be(false)
        expect(notice_failures).to be_empty
      end

      it "失効(expired)では instagram_disconnect を送らず、再認証のフラグ・受信箱の cache の無効化・受信箱の更新の event は出す(#{value.inspect})",
         channel_notice_emails: value do
        channel = instagram(expires_in: -2 * 86_400)

        events = dispatched_events do
          expect { expired_runs.each_key { |hours| run_at(hours) } }.not_to have_enqueued_mail(mailer, :instagram_disconnect)
        end
        expect(channel.reauthorization_required?).to be(true)
        expect(events).to eq(inbox_reauthorized)
        expect(line_for(channel))
          .to eq(expired_runs.values.map { |days| "WARN TOYBACO_INSTAGRAM_TOKEN status=expired inbox=#{channel.inbox.id} days_left=#{days}\n" })
        expect(refresh_request).not_to have_been_made
        expect(ActionMailer::Base.deliveries).to be_empty
        expect(notice_failures).to be_empty
      end
    end

    it '失効の画面の表示の元(フラグと event)は on の時と同じで、違いは instagram_disconnect のメールだけ', channel_notice_emails: nil do
      off_channel = instagram(expires_in: -2 * 86_400)
      off_events = nil
      expect { off_events = dispatched_events { run_job } }.not_to have_enqueued_mail(mailer, :instagram_disconnect)
      # off の受信箱はフラグが立ったので、on の回では on の受信箱だけが通知の対象になる。
      on_channel = instagram(expires_in: -2 * 86_400)
      on_events = nil
      with_modified_env('TOYBACO_CHANNEL_NOTICE_EMAILS' => 'on') do
        expect { on_events = dispatched_events { run_job } }.to have_enqueued_mail(mailer, :instagram_disconnect).once
      end

      expect([off_channel.reauthorization_required?, on_channel.reauthorization_required?]).to eq([true, true])
      expect(off_events).to eq(on_events)
      expect(on_events).to eq(inbox_reauthorized)
    end

    it 'off の間は送らず、on に変えた後の回で、expiring はその時の期限で案内を送る。off の間に失効してフラグが立った受信箱の instagram_disconnect は後から送らない',
       channel_notice_emails: nil do
      stub_request(:get, refresh_url).with(query: hash_including({})).to_return(status: 500, body: '')
      expiring = instagram(expires_in: 6 * 86_400)
      expired = instagram(expires_in: -2 * 86_400)

      run_at(0)
      expect(ActionMailer::Base.deliveries).to be_empty
      expect(expired.reauthorization_required?).to be(true)
      with_modified_env('TOYBACO_CHANNEL_NOTICE_EMAILS' => 'on') do
        expect { [4, 8].each { |hours| run_at(hours) } }.not_to have_enqueued_mail(mailer, :instagram_disconnect)
      end
      mail = ActionMailer::Base.deliveries.sole
      expect(mail.to).to eq(['ig-admin@example.invalid'])
      expect(mail.decoded).to include("Instagram の受信箱「#{expiring.inbox.name}」の接続は、あと 5 日ほどで期限が切れます。")
      expect(notice_stamp(expiring)).to eq(expiring.reload.expires_at.to_i.to_s)
    end

    it '再認証のフラグを立てられなくても TOYBACO_CHANNEL_NOTICE_FAILED の 1 行だけを出し、ほかの受信箱は確かめ続ける', channel_notice_emails: nil do
      broken = instagram(expires_in: -2 * 86_400)
      healthy = instagram(expires_in: 9 * 86_400)
      allow(Redis::Alfred).to receive(:set).and_call_original
      allow(Redis::Alfred).to receive(:set).with(reauthorization_key(broken), true).and_raise(Redis::CannotConnectError, 'secret detail')

      expect { run_job }.not_to have_enqueued_mail(mailer, :instagram_disconnect)
      expect(notice_failures)
        .to eq(["ERROR TOYBACO_CHANNEL_NOTICE_FAILED provider=instagram inbox=#{broken.inbox.id} class=Redis::CannotConnectError\n"])
      expect(line_for(broken)).to eq(["WARN TOYBACO_INSTAGRAM_TOKEN status=expired inbox=#{broken.inbox.id} days_left=-2\n"])
      expect(line_for(healthy)).to eq(["INFO TOYBACO_INSTAGRAM_TOKEN status=refreshed inbox=#{healthy.inbox.id} days_left=60\n"])
      expect(log.string).not_to include('secret detail')
    end
  end
end
