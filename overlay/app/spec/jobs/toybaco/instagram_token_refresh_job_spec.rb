# frozen_string_literal: true

require 'rails_helper'
require 'stringio'

# Instagram の 60 日 token の更新(CW-5、4 時間ごと)。更新の API(graph.instagram.com/refresh_access_token)は WebMock で返す。
# 通知はしない(店舗宛てのメール・再認証のフラグ・Redis への書き込みが無いこと)を、配送を test に替えたうえで確かめる。
RSpec.describe Toybaco::InstagramTokenRefreshJob do
  let(:log) { StringIO.new }
  let(:logger) do
    Logger.new(log, level: :info).tap { |value| value.formatter = proc { |severity, _time, _program, message| "#{severity} #{message}\n" } }
  end
  let(:now) { Time.zone.parse('2026-10-20 04:25:00') }
  let(:account) { create(:account) }
  let(:refresh_url) { 'https://graph.instagram.com/refresh_access_token' }
  let(:admin) { create(:user, account: account, role: :administrator, email: 'ig-admin@example.invalid') }

  # 上流の config/initializers/mailer.rb は SMTP_ADDRESS の無い環境を sendmail にするので、配送だけ test に替える(ops_digest_spec と同じ)。
  around do |example|
    original = [ActionMailer::Base.delivery_method, ActionMailer::Base.perform_deliveries]
    ActionMailer::Base.delivery_method = :test
    ActionMailer::Base.perform_deliveries = true
    example.run
  ensure
    ActionMailer::Base.delivery_method, ActionMailer::Base.perform_deliveries = original
  end

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    admin
    ActionMailer::Base.deliveries.clear
    stub_request(:get, refresh_url).with(query: hash_including('grant_type' => 'ig_refresh_token'))
                                   .to_return(status: 200, body: { access_token: 'refreshed-token-value', expires_in: 5_184_000 }.to_json,
                                              headers: { 'Content-Type' => 'application/json' })
  end

  def instagram(expires_in:, updated_ago: 2 * 86_400)
    travel_to(now) do
      channel = create(:channel_instagram, account: account, access_token: "ig-token-#{SecureRandom.hex(16)}")
      channel.update_columns(expires_at: now + expires_in, updated_at: now - updated_ago) # rubocop:disable Rails/SkipsModelValidations
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

  it '期限まで 7 日以内で更新できなければ expiring を出すだけで、メール・再認証のフラグ・Redis への書き込みはしない' do
    stub_request(:get, refresh_url).with(query: hash_including({})).to_return(status: 500, body: '')
    channel = instagram(expires_in: 6 * 86_400)
    allow(Redis::Alfred).to receive(:set).and_call_original

    expect { run_job }.not_to have_enqueued_job
    expect(line_for(channel)).to eq(["WARN TOYBACO_INSTAGRAM_TOKEN status=expiring inbox=#{channel.inbox.id} days_left=6\n"])
    expect(channel.reauthorization_required?).to be(false)
    expect(Redis::Alfred).not_to have_received(:set)
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it '失効していたら expired を出すだけで、API を呼ばず、メール・再認証のフラグも出さない(何度走っても同じ)' do
    channel = instagram(expires_in: -2 * 86_400)
    allow(Redis::Alfred).to receive(:set).and_call_original

    expect { 2.times { run_job } }.not_to have_enqueued_job
    expect(line_for(channel)).to eq(["WARN TOYBACO_INSTAGRAM_TOKEN status=expired inbox=#{channel.inbox.id} days_left=-2\n"] * 2)
    expect(channel.reauthorization_required?).to be(false)
    expect(Redis::Alfred).not_to have_received(:set)
    expect(refresh_request).not_to have_been_made
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

  it '停止中の店舗の受信箱は確かめない' do
    channel = instagram(expires_in: 9 * 86_400)
    account.update_columns(status: :suspended) # rubocop:disable Rails/SkipsModelValidations

    run_job
    expect(line_for(channel)).to be_empty
    expect(refresh_request).not_to have_been_made
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
end
