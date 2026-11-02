# frozen_string_literal: true

require 'rails_helper'
require 'stringio'

# config/initializers/toybaco_channel_health.rb(CW-4・CW-6)。
# IMAP はパスワード方式の受信箱を Net::IMAP の double で動かし、上流の job / service をそのまま通す。状態は試験用の Redis に置く。
# 店舗の管理者への email_disconnect は TOYBACO_CHANNEL_NOTICE_EMAILS が on の時だけ送る(Toybaco::ChannelNoticeEmails。既定は off)。
RSpec.describe Toybaco::ChannelHealth do
  let(:log) { StringIO.new }
  let(:logger) do
    Logger.new(log, level: :info).tap { |value| value.formatter = proc { |severity, _time, _program, message| "#{severity} #{message}\n" } }
  end
  let(:now) { Time.zone.parse('2026-10-20 10:00:00') }

  before { allow(Rails).to receive(:logger).and_return(logger) }

  # 既存の例は on で流す。off は channel_notice_emails: で値(nil は未設定)を替えた例で見る。env は例の後に元へ戻る。
  around do |example|
    with_modified_env('TOYBACO_CHANNEL_NOTICE_EMAILS' => example.metadata.fetch(:channel_notice_emails, 'on')) { example.run }
  end

  def marker_lines(marker)
    log.string.lines.grep(/#{marker}/)
  end

  describe '日次の token の確認の cron' do
    # Instagram の 4 時間ごとの cron(toybaco_instagram_token_refresh)は config/initializers/toybaco_instagram_token_refresh.rb
    # だけが登録する(停止の設定つき。spec/lib/toybaco/instagram_token_refresh_cron_spec.rb)。ここは LINE の日次だけ。
    it '既存と衝突しない名前で、UTC を明示した LINE の日次の cron だけを scheduled_jobs に登録し、Instagram は登録しない' do
      registered = []
      allow(Sidekiq::Cron::Job).to receive(:create) { |arguments| registered << arguments }

      described_class.register_jobs
      expect(registered).to eq([
                                 { name: 'toybaco_line_token_verify', cron: '35 1 * * * UTC', class: 'Toybaco::LineTokenVerifyJob',
                                   active_job: true, queue: 'scheduled_jobs', source: 'toybaco' }
                               ])
      registered.each { |arguments| expect(Sidekiq::Cron::Job.new(arguments.merge(fetch_missing_args: false))).to be_valid }
      # ECS は TZ=Asia/Tokyo でも UTC で動く(10:35 JST)。
      expect(registered.map { |arguments| Fugit.parse_cron(arguments[:cron]).previous_time(now).utc.strftime('%H:%M') })
        .to eq(%w[01:35])
      initializer_names = Rails.root.glob('config/initializers/*.rb').flat_map { |path| path.read.scan(/name: '([a-z_]+)'/).flatten }
      expect(initializer_names.tally.values_at('toybaco_instagram_token_refresh', 'toybaco_line_token_verify')).to eq([1, 1])
      expect(Rails.root.join('config/initializers/toybaco_channel_health.rb').read).not_to include("name: 'toybaco_instagram_token_refresh'")
      expect(YAML.load_file(Rails.root.join('config/schedule.yml')).keys).not_to include(*registered.pluck(:name))
    end

    it '上流の class へ prepend されている' do
      expect(Imap::Authentication.singleton_class.ancestors).to include(described_class::ImapAuthenticationStage)
      expect(Imap::FetchEmailService.ancestors).to include(described_class::ImapFetch)
      expect(Imap::GoogleFetchEmailService.ancestors).not_to include(described_class::ImapFetch)
      expect(Imap::MicrosoftFetchEmailService.ancestors).not_to include(described_class::ImapFetch)
      expect(Line::IncomingMessageService.ancestors).to include(described_class::LineProfile)
    end
  end

  describe 'パスワード方式の IMAP' do
    let(:account) { create(:account) }
    let(:channel) { create(:channel_email, :imap_email, account: account) }
    let(:imap) { instance_double(Net::IMAP, select: nil, logout: nil) }
    let(:auth) { described_class::ImapAuth }

    before do
      allow(Net::IMAP).to receive(:new).and_return(imap)
      [auth.failures_key(channel), auth.notice_key(channel), auth.email_key(channel), auth.success_key(channel)]
        .each { |key| Redis::Alfred.delete(key) }
    end

    def no_response(text)
      Net::IMAP::NoResponseError.new(Net::IMAP::TaggedResponse.new('RUBY0001', 'NO', Net::IMAP::ResponseText.new(nil, text), ''))
    end

    def authentication_fails
      allow(imap).to receive(:authenticate).and_raise(no_response('[AUTHENTICATIONFAILED] Invalid credentials'))
    end

    def authentication_succeeds(since: nil, seqnos: [])
      allow(imap).to receive(:authenticate)
      allow(imap).to receive(:search) do |query|
        raise "unexpected #{query}" unless since.nil? || query == ['SINCE', since]

        seqnos
      end
    end

    def fetch_job
      travel_to(now) { Inboxes::FetchImapEmailsJob.perform_now(channel) }
    end

    def fetch_service
      travel_to(now) { Imap::FetchEmailService.new(channel: channel, interval: 1).perform }
    end

    it '認証の失敗が 3 回続いたら、固定語のログと email_disconnect のメールを 1 回だけ出す(上流のログはそのまま)' do
      authentication_fails

      expect { 2.times { fetch_job } }.not_to have_enqueued_mail(AdministratorNotifications::ChannelNotificationsMailer, :email_disconnect)
      expect(marker_lines('TOYBACO_IMAP_AUTH_FAILED')).to be_empty
      expect { 3.times { fetch_job } }.to have_enqueued_mail(AdministratorNotifications::ChannelNotificationsMailer, :email_disconnect).once

      expect(marker_lines('TOYBACO_IMAP_AUTH_FAILED')).to eq(["WARN TOYBACO_IMAP_AUTH_FAILED inbox=#{channel.inbox.id} consecutive=3\n"])
      expect(marker_lines("Error for email channel - #{channel.inbox.id} : \\[AUTHENTICATIONFAILED\\] Invalid credentials").size).to eq(5)
      # 再認証のフラグは立てない(上流は取り込みを続け、回復を確かめられる)。
      expect(channel.reauthorization_required?).to be(false)
      expect(Redis::Alfred.get(auth.failures_key(channel))).to eq('5')
    end

    it '回復で数え直し、通知した後の回復は TOYBACO_IMAP_AUTH_RECOVERED を出して、次の連続失敗でまた 1 回だけ知らせる' do
      authentication_fails
      expect { 3.times { fetch_job } }.to have_enqueued_mail(AdministratorNotifications::ChannelNotificationsMailer, :email_disconnect).once

      authentication_succeeds
      fetch_job
      expect(marker_lines('TOYBACO_IMAP_AUTH_RECOVERED')).to eq(["INFO TOYBACO_IMAP_AUTH_RECOVERED inbox=#{channel.inbox.id} since=none\n"])
      expect(Redis::Alfred.get(auth.failures_key(channel))).to be_nil
      expect(Redis::Alfred.get(auth.success_key(channel))).to eq('2026-10-20')

      authentication_fails
      expect { 2.times { fetch_job } }.not_to have_enqueued_mail(AdministratorNotifications::ChannelNotificationsMailer, :email_disconnect)
      expect { fetch_job }.to have_enqueued_mail(AdministratorNotifications::ChannelNotificationsMailer, :email_disconnect).once
      expect(marker_lines('TOYBACO_IMAP_AUTH_FAILED').size).to eq(2)
    end

    it '2 回の失敗の後に成功すれば、通知も回復の行も出さずに数え直す' do
      authentication_fails
      2.times { fetch_job }
      authentication_succeeds
      fetch_job
      authentication_fails

      expect { 2.times { fetch_job } }.not_to have_enqueued_mail(AdministratorNotifications::ChannelNotificationsMailer, :email_disconnect)
      expect(marker_lines('TOYBACO_IMAP_AUTH_(FAILED|RECOVERED)')).to be_empty
      expect(Redis::Alfred.get(auth.failures_key(channel))).to eq('2')
    end

    it '認証の後の段(select)の NO は認証失敗と数えない' do
      allow(imap).to receive(:authenticate)
      allow(imap).to receive(:select).and_raise(no_response('Mailbox does not exist'))

      expect { 4.times { fetch_job } }.not_to have_enqueued_mail(AdministratorNotifications::ChannelNotificationsMailer, :email_disconnect)
      expect(Redis::Alfred.get(auth.failures_key(channel))).to be_nil
      expect(marker_lines('Error for email channel').size).to eq(4)
    end

    it '前回成功した日が無いか今日なら、上流どおり前日から取り込む' do
      authentication_succeeds(since: '19-Oct-2026')
      expect(fetch_service).to eq([])

      expect(fetch_service).to eq([])
      expect(imap).to have_received(:search).with(%w[SINCE 19-Oct-2026]).twice
    end

    it '失敗が続いた後は、前回成功した日から取り込む(前日固定の窓より古いメールを取りこぼさない)' do
      Redis::Alfred.set(auth.success_key(channel), '2026-10-14')
      authentication_succeeds(since: '14-Oct-2026')

      expect(fetch_service).to eq([])
      expect(Redis::Alfred.get(auth.success_key(channel))).to eq('2026-10-20')
    end

    it '遡るのは 30 日まで' do
      Redis::Alfred.set(auth.success_key(channel), '2026-06-01')
      authentication_succeeds(since: '20-Sep-2026')

      expect(fetch_service).to eq([])
    end

    context 'when TOYBACO_CHANNEL_NOTICE_EMAILS is not on' do
      let(:disconnect_mailer) { AdministratorNotifications::ChannelNotificationsMailer }

      [nil, 'off'].each do |value|
        it "3 回続いても email_disconnect を送らず、メールの印も書かず、次の回でも送らない。行・数え方・回復の行・取り込みの済んだ日はそのまま(#{value.inspect})",
           channel_notice_emails: value do
          authentication_fails

          expect { 5.times { fetch_job } }.not_to have_enqueued_mail(disconnect_mailer, :email_disconnect)
          expect(marker_lines('TOYBACO_IMAP_AUTH_FAILED')).to eq(["WARN TOYBACO_IMAP_AUTH_FAILED inbox=#{channel.inbox.id} consecutive=3\n"])
          # メールの印は書かず、数え方はそのまま、再認証のフラグは立てない。
          expect([Redis::Alfred.get(auth.email_key(channel)), Redis::Alfred.get(auth.failures_key(channel)), channel.reauthorization_required?])
            .to eq([nil, '5', false])

          authentication_succeeds
          fetch_job
          expect(marker_lines('TOYBACO_IMAP_AUTH_RECOVERED')).to eq(["INFO TOYBACO_IMAP_AUTH_RECOVERED inbox=#{channel.inbox.id} since=none\n"])
          expect(Redis::Alfred.get(auth.success_key(channel))).to eq('2026-10-20')
          expect(marker_lines('TOYBACO_IMAP_AUTH_TRACKING_FAILED')).to be_empty
        end
      end

      it 'off の間に始まった連続失敗は、on に変えた後の失敗の回で 1 回だけ送る(off の間の回の分は送らない)。固定語の行は 1 回のまま',
         channel_notice_emails: nil do
        authentication_fails
        expect { 3.times { fetch_job } }.not_to have_enqueued_mail(disconnect_mailer, :email_disconnect)

        with_modified_env('TOYBACO_CHANNEL_NOTICE_EMAILS' => 'on') do
          expect { 3.times { fetch_job } }.to have_enqueued_mail(disconnect_mailer, :email_disconnect).once
        end
        expect(marker_lines('TOYBACO_IMAP_AUTH_FAILED')).to eq(["WARN TOYBACO_IMAP_AUTH_FAILED inbox=#{channel.inbox.id} consecutive=3\n"])
        expect(Redis::Alfred.get(auth.email_key(channel))).to eq('2026-10-20')
      end
    end

    it '1 回の上限(MAX_MESSAGES_PER_SYNC)に当たった時は、成功の日を進めず次の回も同じ窓から取る' do
      Redis::Alfred.set(auth.success_key(channel), '2026-10-14')
      max = Imap::BaseFetchEmailService::MAX_MESSAGES_PER_SYNC
      fetch_data = Struct.new(:seqno, :attr)
      headers = (1..max).map do |seqno|
        fetch_data.new(seqno, { 'BODY[HEADER]' => "Message-ID: <probe-#{seqno}@example.invalid>\r\nSubject: probe\r\n\r\n" })
      end
      authentication_succeeds(since: '14-Oct-2026', seqnos: (1..max).to_a)
      # 本文の取得は空で返し、上流の「Fetch failed」の経路で 1 通も作らない(上限に当たったかどうかだけを見る)。
      allow(imap).to receive(:fetch) do |set, item|
        item == 'BODY.PEEK[HEADER]' ? headers.select { |data| Array(set).include?(data.seqno) } : [fetch_data.new(set, { 'BODY[]' => nil })]
      end

      expect(fetch_service).to eq([])
      expect(Redis::Alfred.get(auth.success_key(channel))).to eq('2026-10-14')
    end
  end

  describe 'LINE の get_profile の失敗' do
    let(:line_channel) { create(:channel_line) }
    let(:line_bot) { instance_double(Line::Bot::Client) }
    let(:params) do
      { events: [{ type: 'message', source: { type: 'user', userId: 'U4af4980629' }, message: { id: '325708', type: 'text', text: 'こんにちは' } }] }
        .with_indifferent_access
    end

    before { allow(Line::Bot::Client).to receive(:new).and_return(line_bot) }

    def profile(body)
      allow(line_bot).to receive(:get_profile).with('U4af4980629').and_return(instance_double(Net::HTTPResponse, body: body))
    end

    def receive_message
      Line::IncomingMessageService.new(inbox: line_channel.inbox, params: params).perform
    end

    it 'userId の無い応答(token の失効など)は、上流どおりその件を飛ばしたうえで固定語を出す' do
      profile({ message: 'Authentication failed. Confirm that the access token in the authorization header is valid.' }.to_json)

      expect { receive_message }.not_to change(Message, :count)
      expect(log.string).to include("WARN TOYBACO_LINE_PROFILE_FAILED inbox=#{line_channel.inbox.id} reason=no_user\n")
      expect(log.string).not_to include('Authentication failed')
    end

    it '読めない応答は固定語を出して、上流どおり例外をそのまま上げる' do
      profile('<html>bad gateway</html>')

      expect { receive_message }.to raise_error(JSON::ParserError)
      expect(log.string).to include("WARN TOYBACO_LINE_PROFILE_FAILED inbox=#{line_channel.inbox.id} reason=error class=JSON::ParserError\n")
    end

    it 'userId のある応答は固定語を出さず、上流どおりメッセージを作る' do
      profile({ displayName: 'LINE Test', userId: 'U4af4980629', pictureUrl: 'https://example.invalid/a.png' }.to_json)

      expect { receive_message }.to change(Message, :count).by(1)
      expect(marker_lines('TOYBACO_LINE_PROFILE_FAILED')).to be_empty
    end
  end
end
