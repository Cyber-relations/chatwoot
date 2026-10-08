# frozen_string_literal: true

require 'digest'
require 'net/imap'
require 'openssl'
require 'socket'
require 'time'
require 'timeout'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # 自動応答の体験の対象にする IMAP の受信箱に、Toybaco が実際にログインして確かめる(TrialConnection)。
    # Chatwoot の受信箱の更新は IMAP の検証に失敗しても設定を保存し(imap_enabled を含まない更新では検証もしない)、fetch job も
    # パスワードの認証失敗では再認証を求めない。保存値は受信箱の所有の証明にならないので、体験の identity はここでの実認証で担保する。
    # - 判定・ログイン・記録は、受信箱の行ロックの中で直列に行う(並行した確認が同時に上限を通らない。ロックを持つのは最大 12 秒)。
    #   待っていた側はロックを取ったあとの最新の記録と設定で判定する(記録の時刻もロックを取ってから読む)。確かめる時点の設定
    #   (Snapshot)から指紋と identity を作り、成功は受信箱を読み直して設定が同じときだけ記録する(確かめていない設定の成功にならない)。
    # - 結果は provider_config['toybaco_imap_verified'] に、指紋と時刻と試行の回数だけを残す。指紋はアプリの鍵の HMAC にする
    #   (DB の値だけではパスワードを総当たりで確かめられない)。パスワードの平文とログイン名は、ログにも記録にも書かない。
    # - 記録は行ロックの中で、最新の provider_config にこのキーだけを merge して update_columns で書く(検証・コールバック・touch を
    #   通さない)。Channelable の touch による Inbox の行ロックを避けるため。受信箱の更新 API は Inbox → Channel の順に書くので、
    #   Channel の行ロックを持ったまま Inbox に書くと順序が逆になり、デッドロックする。
    # - 同じ指紋なら、成功から 7 日・失敗から 10 分は接続し直さない(画面の表示ごとに接続しない)。設定が変われば確かめ直す。
    # - ログインを試した回数を受信箱ごとに数え(成功・失敗を問わない)、10 分以内に 3 回試したら、その時刻から 10 分間は接続しない
    #   (パスワード・ログイン・ホストを変えながらの総当たりを抑える。自前のホストへの成功を挟んでも減らない)。回数は期限が過ぎた
    #   ときだけ 1 回目から数え直し、今の窓の中では回数も窓の始まりも小さくしない。同じ指紋の成功の記録(7 日)は回数より先に
    #   効くので、正しく設定した受信箱は接続し直さない。
    # - 体験の開始は店舗のロックの外でここを呼ぶ(TrialStart)ので、開始の巻き戻しでは記録は消えない。外側のトランザクションの
    #   中で呼ばれてそれが巻き戻されたときは、行ロックを取って最新の値に同じ記録を足し直す(試行の回数は最新の回数に足す。
    #   成功・失敗の記録は、受信箱の設定が試した設定のままのときだけ足す。確かめた設定の指紋にだけ結びつくので他の設定は通らない)。
    # - 接続するのは体験の開始と開始画面(verified?)だけで、体験中の予約・返信・受信箱の状態表示は記録の指紋が今の設定と一致するか
    #   (recorded?)だけを見る。
    # 残る前提: 本人のホストにログインできる人 = 受信箱の所有者(パスワードを知っている第三者も所有者と同じに扱う)。
    # Rails と ActiveSupport が無くても require できる(Rails を読まない素の Ruby のテストが onboarding から読み込む)。Rails・
    # Imap::Authentication・Channel::Email・ActiveRecord はメソッドの中でだけ参照し、ActiveSupport の拡張(present? や 7.days)は使わない。
    # 実認証・スナップショットの照合・試行の上限と巻き戻し後の書き直しを、記録の形とともに 1 か所にまとめるため長い。
    module ImapVerification # rubocop:disable Metrics/ModuleLength
      KEY = 'toybaco_imap_verified'
      # Chatwoot の認証方式のうち、ログインとパスワードで確かめられるもの(xoauth2 などは対象外)。
      MECHANISMS = %w[plain login].freeze
      # 期間は秒で持つ(ActiveSupport の Duration を使わない)。成功の記録は 7 日、失敗の記録は 10 分、試行の回数は 10 分の窓で見る。
      VERIFIED_FOR = 7 * 24 * 60 * 60
      FAILED_FOR = 10 * 60
      ATTEMPT_WINDOW = 10 * 60
      # 同じ受信箱で、10 分以内にこの回数ログインを試したら(成功・失敗を問わない)、その時刻から 10 分間は接続しない。
      ATTEMPT_LIMIT = 3
      OPEN_TIMEOUT = 8
      TIMEOUT = 12
      FAILURES = [Net::IMAP::Error, SocketError, Timeout::Error, OpenSSL::SSL::SSLError, SystemCallError, IOError].freeze

      # 確かめる時点の設定。パスワードは SHA256 だけを持つ(平文はログインの直前に受信箱から読む)。
      Snapshot = Data.define(:host, :port, :ssl, :login, :password_sha256, :mechanism)

      module_function

      def snapshot(channel)
        password = channel.imap_password.to_s
        Snapshot.new(host: host(channel.imap_address), port: channel.imap_port.to_i, ssl: channel.imap_enable_ssl == true,
                     login: channel.imap_login.to_s.strip, password_sha256: (Digest::SHA256.hexdigest(password) if filled?(password)),
                     mechanism: ::Imap::Authentication.normalize(channel.imap_authentication).to_s.downcase)
      end

      # ホストは前後の空白・大文字小文字・末尾のドットを区別しない(mail.example.com. = mail.example.com)。
      def host(value)
        value.to_s.strip.downcase.sub(/\.+\z/, '')
      end

      # 空白(全角の空白などを含む)以外の文字を含むか。ActiveSupport の present? と同じ判定を素の Ruby で書く。
      def filled?(value)
        value.to_s.match?(/[^[:space:]]/)
      end

      # 体験の開始と開始画面の判定。記録で決まらなければ実際にログインして確かめる。時刻は行ロックを取ってから読む(ロックを
      # 待つ間に他の確認が書いた記録より前の時刻で数えない)。
      def verified?(channel, captured = snapshot(channel))
        return false unless verifiable?(channel, captured)

        channel.with_lock { verify_locked(channel, captured, Time.now.utc) }
      end

      # 行ロックの中の判定(lock! が受信箱を読み直している)。待つ間に設定が変わっていれば、この設定では確かめない。
      def verify_locked(channel, captured, now)
        return false unless snapshot(channel) == captured && verifiable?(channel, captured)

        fingerprint = fingerprint(captured)
        cached = cached_result(recorded(channel), fingerprint, now)
        return cached unless cached.nil?

        record_attempt!(channel, captured, fingerprint, signed_in?(channel, captured), now)
      end

      # 体験中の経路の判定。成功の記録の指紋が今の設定と一致するかだけを見る(成功の期限も失敗の記録も見ず、接続しない)。
      def recorded?(channel, captured = snapshot(channel))
        verifiable?(channel, captured) && recorded(channel)['fingerprint'] == fingerprint(captured)
      end

      # 今の設定の成功が期限(7 日)内に記録されているか。断る理由の判定(TrialConnection.imap_unverified?)に使う。接続しない。
      # 体験中の allowed? は recorded?(期限を見ない)のまま。時刻は verified? と同じく Time.now.utc で読む。
      def fresh?(channel, captured = snapshot(channel))
        verifiable?(channel, captured) && cached_result(recorded(channel), fingerprint(captured), Time.now.utc) == true
      end

      # 確かめられる設定か。Gmail のアドレスのホストの条件など、identity の規則は TrialConnection が見る。
      def verifiable?(channel, captured)
        TrialConnection.imap_mailbox?(channel) && MECHANISMS.include?(captured.mechanism) && filled?(captured.host) &&
          captured.port.positive? && filled?(captured.password_sha256) &&
          captured.password_sha256 == Digest::SHA256.hexdigest(channel.imap_password.to_s)
      end

      # 記録から決まる結果。同じ指紋の成功(7 日)は true、同じ指紋の失敗(10 分)と、受信箱の試行の上限は false。
      # 決まらなければ nil(接続して確かめる)。成功の記録を先に見るので、上限の間も確かめ済みの設定は true のまま(接続しない)。
      def cached_result(record, fingerprint, now)
        return true if record['fingerprint'] == fingerprint && within?(record['verified_at'], VERIFIED_FOR, now)
        return false if record['failed_fingerprint'] == fingerprint && within?(record['failed_at'], FAILED_FOR, now)

        false if throttled?(record, now)
      end

      def fingerprint(captured)
        hmac([captured.host, captured.port, captured.ssl, captured.login.downcase, captured.password_sha256].join('|'))
      end

      def hmac(source)
        OpenSSL::HMAC.hexdigest('SHA256', Rails.application.key_generator.generate_key('toybaco-imap-verification-v1', 32), source)
      end

      def recorded(channel)
        record = channel.provider_config.is_a?(Hash) ? channel.provider_config[KEY] : nil
        record.is_a?(Hash) ? record : {}
      end

      # 試行の上限。今の窓で 3 回試していれば、3 回目の時刻(first_at を進めてある)から 10 分間は接続しない。
      def throttled?(record, now)
        attempts = record['attempts']
        attempts.is_a?(Hash) && attempts['count'].to_i >= ATTEMPT_LIMIT && current_window?(attempts['first_at'], now)
      end

      # 試行の回数の今の窓か。first_at から 10 分以内なら今の窓。時計のずれで first_at が now より後でも(10 分以内なら)今の窓と
      # みなす(数え直して回数を減らさない)。読めない値と、10 分より先の値は窓なし。
      def current_window?(first_at, now)
        time = parsed_time(first_at)
        !time.nil? && time > now - ATTEMPT_WINDOW && time <= now + ATTEMPT_WINDOW
      end

      def within?(at, window, now)
        time = parsed_time(at)
        !time.nil? && time <= now && time > now - window
      end

      def parsed_time(value)
        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      # Chatwoot の受信と同じ認証の手順(Imap::Authentication)で、確かめる時点の設定でログインし、すぐにログアウトする。
      # authenticate! を抜けた時点でログインは確かめられている。その後のログアウト・切断・時間切れの失敗では成功を捨てない
      # (ログには理由のクラスだけを書く)。
      def signed_in?(channel, captured)
        imap = nil
        authenticated = false
        Timeout.timeout(TIMEOUT) do
          imap = Net::IMAP.new(captured.host, port: captured.port, ssl: captured.ssl, open_timeout: OPEN_TIMEOUT)
          ::Imap::Authentication.authenticate!(imap, captured.mechanism, captured.login, channel.imap_password.to_s)
          authenticated = true
          imap.logout
        end
        true
      rescue *FAILURES => e
        stage = authenticated ? 'logout failed after sign-in' : 'sign-in failed'
        Rails.logger.info("[Toybaco::Growth::ImapVerification] channel=#{channel.id} #{stage}: #{e.class}")
        authenticated
      ensure
        disconnect(imap)
      end

      def disconnect(imap)
        imap.disconnect if imap && !imap.disconnected?
      rescue StandardError
        nil
      end

      # ログインを試した結果を記録し、確かめられたかを返す(行ロックの中)。試行の回数は結果によらず足す。受信箱を読み直し、
      # 成功は今の設定が確かめた設定と同じときだけ成功として記録する(違えば回数だけ)。外側のトランザクション(体験の開始)が
      # 巻き戻されたら、同じ記録を書き直す。
      def record_attempt!(channel, captured, fingerprint, signed_in, now)
        channel.reload
        outcome = attempt_outcome(signed_in, snapshot(channel) == captured)
        write_record!(channel, applied(recorded(channel), outcome, fingerprint, now))
        ActiveRecord::Base.current_transaction.after_rollback { rewrite!(channel.id, outcome, fingerprint) }
        outcome == :succeeded
      end

      # 試行の結果。ログインできなければ :failed、できて設定も確かめた時点と同じなら :succeeded、確かめる間に設定が変わったら
      # :changed(回数だけを数える)。
      def attempt_outcome(signed_in, unchanged)
        return :failed unless signed_in

        unchanged ? :succeeded : :changed
      end

      # 巻き戻しの後の書き直し。行ロックを取って最新の provider_config に同じ記録を足す(並行して保存された記録や他のキーを
      # 消さない。行が無ければ何もしない)。時刻はロックを取ってから読み、試行の回数は待つ間に他の確認が数えた最新の回数に足す。
      # 成功・失敗の記録は、受信箱の今の設定が試した設定のままのときだけ足す(設定が変わっていれば回数だけ。新しい設定の記録を
      # 古い設定の結果で上書きしない)。
      def rewrite!(channel_id, outcome, fingerprint)
        Channel::Email.transaction do
          row = Channel::Email.lock.find_by(id: channel_id)
          next unless row

          kept = fingerprint(snapshot(row)) == fingerprint ? outcome : :changed
          write_record!(row, applied(recorded(row), kept, fingerprint, Time.now.utc))
        end
      end

      # 試行 1 回分の結果を記録に足す。成功は指紋と時刻、失敗は失敗の指紋と時刻、確かめる間に設定が変わったときは回数だけ
      # (成功は失敗の記録を消さない。同じ指紋なら成功の記録が先に効く)。
      def applied(record, outcome, fingerprint, now)
        counted = attempted(record, now)
        case outcome
        when :succeeded then counted.merge('fingerprint' => fingerprint, 'verified_at' => now.iso8601)
        when :failed then counted.merge('failed_fingerprint' => fingerprint, 'failed_at' => now.iso8601)
        else counted
        end
      end

      # 試行の回数を 1 足す。今の窓なら最新の回数に 1 足し(回数を減らさない)、上限に届いたら first_at をその時刻まで進める
      # (戻さない。そこから 10 分間は接続しない)。窓が過ぎていれば(または無ければ)1 回目から数え直す(成功では数え直さない)。
      def attempted(record, now)
        attempts = record['attempts'].is_a?(Hash) ? record['attempts'] : {}
        return record.merge('attempts' => { 'count' => 1, 'first_at' => now.iso8601 }) unless current_window?(attempts['first_at'], now)

        count = attempts['count'].to_i + 1
        first = count >= ATTEMPT_LIMIT && parsed_time(attempts['first_at']) < now ? now.iso8601 : attempts['first_at']
        record.merge('attempts' => { 'count' => count, 'first_at' => first })
      end

      # 記録を、行ロックを持った受信箱の最新の provider_config に merge して書く(このキー以外と受信箱の他の値には触れない)。
      # update_columns なので検証・コールバック・touch を通らず、Inbox の行には書かない(冒頭の説明)。
      def write_record!(row, record)
        row.update_columns(provider_config: provider_config(row).merge(KEY => record)) # rubocop:disable Rails/SkipsModelValidations
      end

      def provider_config(channel)
        channel.provider_config.is_a?(Hash) ? channel.provider_config : {}
      end
    end
  end
end
