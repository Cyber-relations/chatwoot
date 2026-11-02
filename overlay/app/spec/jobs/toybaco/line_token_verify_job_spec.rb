# frozen_string_literal: true

require 'rails_helper'
require 'stringio'

# LINE の channel access token の日次の検証(CW-4)。verify API(POST https://api.line.me/v2/oauth/verify)は WebMock で返す。
# 店舗の管理者への案内は TOYBACO_CHANNEL_NOTICE_EMAILS が on の時だけ送る(Toybaco::ChannelNoticeEmails。既定は off)。
RSpec.describe Toybaco::LineTokenVerifyJob do
  let(:log) { StringIO.new }
  let(:logger) do
    Logger.new(log, level: :info).tap { |value| value.formatter = proc { |severity, _time, _program, message| "#{severity} #{message}\n" } }
  end
  let(:verify_url) { 'https://api.line.me/v2/oauth/verify' }
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator, email: 'line-admin@example.invalid') }
  let(:agent) { create(:user, account: account, role: :agent, email: 'line-agent@example.invalid') }
  let(:channel) { line_channel('1650000001', 'line-token-secret-value') }
  # 期限前(expiring)の案内は日本時間 9 時以上 18 時未満の回にだけ送るので、送る例は cron と同じ 10:35 JST で流す。
  let(:daytime) { Time.utc(2026, 10, 20, 1, 35) }

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
    Redis::Alfred.delete("TOYBACO_LINE_TOKEN_NOTICE::#{channel.id}")
  end

  def line_channel(channel_id, token)
    create(:channel_line, account: account, inbox: create(:inbox, account: account, name: 'LINE 受信箱'), line_channel_id: channel_id,
                          line_channel_token: token)
  end

  def verify_returns(status:, body: nil, content_type: 'application/json', token: 'line-token-secret-value')
    stub_request(:post, verify_url).with(body: { 'access_token' => token })
                                   .to_return(status: status, body: body.is_a?(Hash) ? body.to_json : body.to_s,
                                              headers: { 'Content-Type' => content_type })
  end

  def lines
    log.string.lines.grep(/TOYBACO_LINE_TOKEN /)
  end

  def line(status, kind, days)
    "TOYBACO_LINE_TOKEN status=#{status} inbox=#{channel.inbox.id} kind=#{kind} days_left=#{days}\n"
  end

  def notice_stamp
    Redis::Alfred.get("TOYBACO_LINE_TOKEN_NOTICE::#{channel.id}")
  end

  def run_at(time)
    travel_to(time) { described_class.perform_now }
  end

  it '長期 token(30 日を超える expires_in)は valid で、通知しない' do
    verify_returns(status: 200, body: { client_id: '1650000001', expires_in: 3_138_007_490, scope: 'P' })

    described_class.perform_now
    expect(lines).to eq(["INFO #{line('valid', 'long_lived', 36_319)}"])
    expect(ActionMailer::Base.deliveries).to be_empty
    expect(a_request(:post, verify_url)).to have_been_made.once
  end

  it 'expires_in の無い応答は期限の無い長期 token として valid にする' do
    verify_returns(status: 200, body: { client_id: '1650000001', scope: 'P' })

    described_class.perform_now
    expect(lines).to eq(["INFO #{line('valid', 'long_lived', 'none')}"])
  end

  it '短期 token(30 日以内に切れる)は expiring で、店舗の管理者だけへ日本語の案内を 1 回だけ送る(運営への Cc・Bcc なし)' do
    verify_returns(status: 200, body: { client_id: '1650000001', expires_in: (12 * 86_400) + 5, scope: 'P' })
    allow(Toybaco::ChannelNoticeMailer).to receive(:with).and_call_original
    operations_env = { 'TOYBACO_OPERATIONS_EMAIL' => 'ops@example.invalid', 'TOYBACO_OPERATIONS_ALERT_EMAIL' => 'ops-alert@example.invalid' }

    with_modified_env(operations_env) { 2.times { run_at(daytime) } }
    expect(lines).to eq(["WARN #{line('expiring', 'short_lived', 12)}"] * 2)
    mail = ActionMailer::Base.deliveries.sole
    expect([mail.to, mail.cc, mail.bcc]).to eq([['line-admin@example.invalid'], nil, nil])
    expect(Toybaco::ChannelNoticeMailer).to have_received(:with).once
    expect(mail.subject).to eq("【トイバコ】LINE のチャネルアクセストークンを更新してください(#{channel.inbox.name})")
    expect(mail.decoded).to include('LINE の受信箱「LINE 受信箱」のチャネルアクセストークンは、あと 12 日ほどで期限が切れます。')
    expect(mail.decoded).to include("/app/accounts/#{account.id}/settings/inboxes/#{channel.inbox.id}")
    expect(mail.decoded).not_to include('line-token-secret-value')
  end

  it '無効な token(400)は invalid で、管理者へ案内を送る。token を更新すれば再び確かめて知らせる' do
    verify_returns(status: 400, body: { error: 'invalid_request', error_description: 'access token expired' })

    described_class.perform_now
    described_class.perform_now
    expect(lines).to eq(["WARN #{line('invalid', 'unknown', 'none')}"] * 2)
    expect(ActionMailer::Base.deliveries.sole.decoded).to include('のチャネルアクセストークンが無効になっています。')
    expect(log.string).not_to include('access token expired')

    verify_returns(status: 400, body: { error: 'invalid_request' }, token: 'line-token-renewed-value')
    travel_to(1.minute.from_now) { channel.update!(line_channel_token: 'line-token-renewed-value') }
    described_class.perform_now
    expect(ActionMailer::Base.deliveries.size).to eq(2)
  end

  it '別のチャネルの token(client_id の不一致)は invalid にする' do
    verify_returns(status: 200, body: { client_id: '1659999999', expires_in: 3_138_007_490, scope: 'P' })

    described_class.perform_now
    expect(lines).to eq(["WARN #{line('invalid', 'unknown', 'none')}"])
  end

  it '確かめられない時(5xx・通信の例外・読めない応答)は failed で、通知しない' do
    stub_request(:post, verify_url).to_return({ status: 503, body: '' }, { status: 200, body: '<html>', headers: { 'Content-Type' => 'text/html' } })
                                   .then.to_raise(Errno::ECONNRESET)

    3.times { described_class.perform_now }
    expect(lines).to eq(["WARN #{line('failed', 'unknown', 'none')}"] * 3)
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it '1 件の例外は failed と例外の class だけを出し、ほかの受信箱は確かめ続ける' do
    channel
    other = line_channel('1650000002', 'other-token-value')
    verify_returns(status: 200, body: { client_id: '1650000002', expires_in: 3_138_007_490 }, token: 'other-token-value')
    job = described_class.new
    allow(job).to receive(:request).and_wrap_original do |original, token|
      raise ActiveRecord::Encryption::Errors::Decryption, 'secret detail' if token == 'line-token-secret-value'

      original.call(token)
    end

    job.perform_now
    expect(lines).to eq(["WARN #{line('failed', 'unknown', 'none').chomp} error=ActiveRecord::Encryption::Errors::Decryption\n",
                         "INFO TOYBACO_LINE_TOKEN status=valid inbox=#{other.inbox.id} kind=long_lived days_left=36319\n"])
    expect(log.string).not_to include('secret detail')
  end

  it '停止中の店舗の受信箱は確かめない' do
    channel
    account.update_columns(status: :suspended) # rubocop:disable Rails/SkipsModelValidations

    described_class.perform_now
    expect(lines).to be_empty
    expect(a_request(:post, verify_url)).not_to have_been_made
  end

  context 'when TOYBACO_CHANNEL_NOTICE_EMAILS is not on' do
    [nil, 'off'].each do |value|
      it "expiring・invalid でも案内を送らず、送った印も書かず、次の回でも送らない。行はそのまま(#{value.inspect})",
         channel_notice_emails: value do
        verify_returns(status: 200, body: { client_id: '1650000001', expires_in: (12 * 86_400) + 5, scope: 'P' })
        allow(Toybaco::ChannelNoticeMailer).to receive(:with).and_call_original

        2.times { run_at(daytime) }
        verify_returns(status: 400, body: { error: 'invalid_request' })
        2.times { run_at(daytime) }
        expect(lines).to eq((["WARN #{line('expiring', 'short_lived', 12)}"] * 2) + (["WARN #{line('invalid', 'unknown', 'none')}"] * 2))
        expect(Toybaco::ChannelNoticeMailer).not_to have_received(:with)
        expect(ActionMailer::Base.deliveries).to be_empty
        expect(notice_stamp).to be_nil
        expect(log.string).not_to include('TOYBACO_CHANNEL_NOTICE_FAILED')
      end
    end

    it 'off の間は送らず、on に変えた後の回でその時の状態の案内を 1 回だけ送る(off の間の回の分は送り直さない)', channel_notice_emails: nil do
      verify_returns(status: 200, body: { client_id: '1650000001', expires_in: (12 * 86_400) + 5, scope: 'P' })

      2.times { run_at(daytime) }
      expect(ActionMailer::Base.deliveries).to be_empty
      with_modified_env('TOYBACO_CHANNEL_NOTICE_EMAILS' => 'on') { 2.times { run_at(daytime) } }
      mail = ActionMailer::Base.deliveries.sole
      expect(mail.to).to eq(['line-admin@example.invalid'])
      expect(mail.decoded).to include('のチャネルアクセストークンは、あと 12 日ほどで期限が切れます。')
      expect(notice_stamp).to eq("expiring:#{channel.reload.updated_at.to_i}")
      expect(lines).to eq(["WARN #{line('expiring', 'short_lived', 12)}"] * 4)
    end
  end

  # cron の 10:35 JST は job を積む時刻しか決めない。queue の滞留や worker の復旧で遅れた回は、送る直前の時刻で判定する。
  context 'with the Japan time window for the expiring notice' do
    it '夜間(23:00 JST)に遅れて走った回は期限前の案内を送らず印も書かず、行は出す。次の対象の回(翌日 10:35 JST)で送る' do
      verify_returns(status: 200, body: { client_id: '1650000001', expires_in: (12 * 86_400) + 5, scope: 'P' })

      run_at(Time.utc(2026, 10, 20, 14, 0))
      expect(ActionMailer::Base.deliveries).to be_empty
      expect(notice_stamp).to be_nil
      expect(lines).to eq(["WARN #{line('expiring', 'short_lived', 12)}"])
      expect(log.string).not_to include('TOYBACO_CHANNEL_NOTICE_FAILED')

      run_at(Time.utc(2026, 10, 21, 1, 35))
      expect(ActionMailer::Base.deliveries.map(&:to)).to eq([['line-admin@example.invalid']])
      expect(ActionMailer::Base.deliveries.sole.decoded).to include('あと 12 日ほどで期限が切れます。')
      expect(notice_stamp).to eq("expiring:#{channel.reload.updated_at.to_i}")
    end

    it '境目: 08:59 は送らず 09:00 は送り、17:59 は送り 18:00 は送らない(ENV の TZ と Time.zone に依らない)' do
      verify_returns(status: 200, body: { client_id: '1650000001', expires_in: (12 * 86_400) + 5, scope: 'P' })
      boundaries = [Time.utc(2026, 10, 20, 23, 59), Time.utc(2026, 10, 21, 0, 0), Time.utc(2026, 10, 21, 8, 59), Time.utc(2026, 10, 21, 9, 0)]

      sent = [%w[UTC UTC], %w[Asia/Tokyo Asia/Tokyo]].map do |tz, zone|
        with_modified_env('TZ' => tz) do
          Time.use_zone(zone) do
            boundaries.map do |time|
              Redis::Alfred.delete("TOYBACO_LINE_TOKEN_NOTICE::#{channel.id}")
              ActionMailer::Base.deliveries.clear
              run_at(time)
              [ActionMailer::Base.deliveries.size, notice_stamp.nil?]
            end
          end
        end
      end
      expect(sent).to eq([[[0, true], [1, false], [1, false], [0, true]]] * 2)
      expect(lines.size).to eq(8)
    end

    it '無効(invalid)の案内は受信も返信も止まっているので、夜間の回でも送る' do
      verify_returns(status: 401, body: { error: 'invalid_token' })

      run_at(Time.utc(2026, 10, 20, 14, 0))
      expect(ActionMailer::Base.deliveries.sole.decoded).to include('のチャネルアクセストークンが無効になっています。')
      expect(notice_stamp).to eq("invalid:#{channel.reload.updated_at.to_i}")
    end
  end
end
