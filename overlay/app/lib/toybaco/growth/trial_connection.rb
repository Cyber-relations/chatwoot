# frozen_string_literal: true

require 'openssl'
require_relative '../connections/gmail'
require_relative '../connections/microsoft'
require_relative 'imap_verification'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # 体験の identity = 受信箱の所有が確認できる接続(API の OAuth、または IMAP 認証)。
    # 転送だけの受信箱は誰でも任意のアドレスを名乗れるので対象外。
    # IMAP の受信箱は、Toybaco が実際にログインできたもの(ImapVerification)だけを対象にする。Chatwoot の受信箱の更新は IMAP の
    # 検証に失敗しても設定を保存し、fetch job もパスワードの認証失敗では再認証を求めないので、保存値は所有の証明にならない。
    # identity は、確かめた時点の設定(スナップショット)の、認証したアカウント(imap_login)とホストで作る。
    # 返信経路は実認証しない(体験開始時と開始画面だけが接続する)。体験中の予約・返信・受信箱の状態表示(allowed?)は、
    # 開始のときに残したログインの記録が今の設定と一致するかだけを見る。体験の開始は店舗のロックの前に接続し(identity)、
    # ロックの中は記録だけで identity を作る(recorded_identity。TrialStart)。
    # identities の一意索引は provider と identity_digest の組。Gmail と Google Workspace は、API と IMAP の接続を同じ枠として数える。
    # - imap.gmail.com に SSL でログインする受信箱は、アドレスのドメインによらず API 接続と同じ 'gmail' の identity にする
    #   (Gmail と Google Workspace のどちらも、API と IMAP で同じ枠)。SSL でなければ対象外。他のホストで Gmail のアドレスを
    #   名乗る受信箱も対象外。
    # - それ以外のアドレスは 'imap' で、ホストを含めて数える。他人のアドレスを自前のホストで名乗っても、本人の identity
    #   (本来のホスト、または API 接続)とは一致しないので、本人の体験の枠は潰せない。
    # 残るリスク:
    # - 自前のホストで偽のログインを量産すれば、店舗ごとに 1 回(100 回分)の体験を取れる。規模は無料プランの濫用と同じく、
    #   確認済みのメールアドレスで作れる店舗の数に比例する(登録は Rack::Attack の toybaco_free_signup/ip で IP あたり 10 件/時)。
    #   体験開始数の監視は別に行う。
    # - Microsoft 365 は API と IMAP で identity が分かれる。API 接続の開放後に同じ受信箱で 2 回体験できる(規模は店舗 2 つ分)。
    #   API 接続の受信箱のアドレス(channel.email)は受信箱の更新で書き換えられるので、IMAP の枠を API 側から作ることはしない。
    # - 本人のホストにログインできる人を受信箱の所有者として扱う(パスワードを知っている第三者も同じ)。
    # - Gmail の API 接続の identity は書き換えられる channel.email から作る(main 既存・Gmail API 未開放。OAuth の subject を固定する別 slice で直す)。
    # Rails と ActiveSupport が無くても require できる(Rails を読まない素の Ruby のテストが onboarding から読み込む)。Rails・
    # Channel::Email・Toybaco::GrowthTrial はメソッドの中でだけ参照し、ActiveSupport の拡張(present? など)は使わない
    # (空白の判定は ImapVerification.filled?)。
    class TrialConnection
      # Gmail と Google Workspace の IMAP のホスト(大文字小文字と末尾のドットは区別しない)。
      GOOGLE_IMAP_HOST = 'imap.gmail.com'

      # verification: IMAP の受信箱の確かめ方。:full は実際にログインして確かめ(体験の開始の店舗のロックの前と開始画面)、
      # :recorded はログインの記録だけを見て接続しない(recorded_identity と同じ)。
      def self.identity(inbox, verification: :full)
        identity_of(resolved(inbox, verification))
      end

      # ログインの記録だけで作る identity(接続しない)。体験の開始の店舗のロックの中と、体験中の allowed? で使う。
      def self.recorded_identity(inbox)
        identity_of(resolved(inbox, :recorded))
      end

      def self.identity_of(resolved)
        provider, external_id = resolved
        digest(provider, external_id) if external_id
      end

      def self.digest(provider, external_id)
        key = Rails.application.key_generator.generate_key('toybaco-trial-identity-v1', 32)
        { provider: provider, identity_digest: OpenSSL::HMAC.hexdigest('SHA256', key, external_id) }
      end

      def self.ready?(inbox, verification: :full)
        !resolved(inbox, verification).nil?
      end

      # identity の元(provider と external_id)。対象外なら nil。
      def self.resolved(inbox, verification)
        channel = inbox.channel
        return unless channel.respond_to?(:reauthorization_required?)
        return if channel.reauthorization_required? || !inbox.agent_bot_inbox&.active?
        return gmail_resolved(channel, inbox.account) if Connections::Gmail.connected?(channel)
        return microsoft_resolved(channel, inbox.account) if Connections::Microsoft.connected?(channel)

        imap_resolved(channel, verification)
      end

      def self.gmail_resolved(channel, account)
        ['gmail', normalized_email(channel.email)] if Connections::Gmail.allowed?(account)
      end

      def self.microsoft_resolved(channel, account)
        ['microsoft', Connections::Microsoft.config(channel)['subject_id']] if microsoft_ready?(channel, account)
      end

      # Microsoft の API 接続は、いまのアプリ登録・実装の版で接続し、この店舗に開放済みのときだけ。
      def self.microsoft_ready?(channel, account)
        Connections::Microsoft.application_current?(channel) && Connections::Microsoft.allowed?(account)
      end

      # IMAP の受信箱。確かめる時点の設定(スナップショット)で identity の規則を見てから確かめ、identity も同じ値から作る。
      # 規則に合わない受信箱には接続しない。確かめている間に別の接続で設定が変わっても、確かめていない設定で identity を作らない
      # (ImapVerification が成功を記録する前に読み直して照らし合わせる)。
      def self.imap_resolved(channel, verification)
        return unless imap_mailbox?(channel)

        captured = ImapVerification.snapshot(channel)
        rule = imap_rule(captured, channel)
        return unless rule

        ok = verification == :recorded ? ImapVerification.recorded?(channel, captured) : ImapVerification.verified?(channel, captured)
        rule if ok
      end

      # IMAP の受信箱の identity の規則(確かめずに、今の設定で見る)。ガイドと、体験の開始を断る理由に使う。
      def self.imap_identity(channel)
        imap_rule(ImapVerification.snapshot(channel), channel) if imap_mailbox?(channel)
      end

      # 認証したアカウント(imap_login、無ければ受信箱のアドレス)で数える。imap.gmail.com は SSL のときだけ 'gmail'、
      # 他のホストの Gmail のアドレスは対象外、それ以外は 'imap' + ホスト込み。
      def self.imap_rule(captured, channel)
        login = captured.login
        address = normalized_email(ImapVerification.filled?(login) ? login : channel.email.to_s.strip)
        return unless address
        return google_rule(captured, address) if captured.host == GOOGLE_IMAP_HOST
        return if address.split('@', 2).last == 'gmail.com'

        ['imap', "#{captured.host}/#{address}"]
      end

      # Google が認証するホスト。平文や証明書の検証に失敗する接続は identity を出さない(SSL のときだけ)。
      def self.google_rule(captured, address)
        ['gmail', address] if captured.ssl
      end

      # 体験の開始を断る理由の判定(TrialStart)。回答例の受信箱が IMAP の規則に合うのに、ログインを確かめられないとき。
      # 接続しない。開始の経路で直前の identity(:full) が残した記録だけを見る。今の設定の成功が期限(7 日)内に記録されて
      # いなければ真(ImapVerification.fresh?。期限を見ない recorded? では、同じ設定の古い成功の記録が残る受信箱のログイン
      # 失敗と試行の上限を見落とす)。resolved が IMAP の確認の前に抜ける受信箱(imap_checked? が偽)は、ログインを試して
      # いないので対象外(他の理由で断る)。
      def self.imap_unverified?(inbox)
        channel = inbox.channel
        return false unless imap_checked?(inbox, channel)

        !imap_identity(channel).nil? && !ImapVerification.fresh?(channel)
      end

      # resolved が IMAP の確認まで進む受信箱か。resolved と同じ早期終了を同じ順で見る(再認証の要求・ボットが有効でない・
      # Gmail と Microsoft の API 接続は偽)。
      def self.imap_checked?(inbox, channel)
        return false unless channel.respond_to?(:reauthorization_required?)
        return false if channel.reauthorization_required? || !inbox.agent_bot_inbox&.active?

        !Connections::Gmail.connected?(channel) && !Connections::Microsoft.connected?(channel)
      end

      # 体験の開始を断る理由の判定(TrialStart)。回答例の受信箱が、体験の規則に合わない標準メール受信箱のとき
      # (他のホストの Gmail のアドレス、SSL でない imap.gmail.com、転送だけの受信箱など)。API 接続は含めない。接続はしない。
      def self.imap_rule_mismatch?(inbox)
        channel = inbox.channel
        return false unless channel.is_a?(Channel::Email)
        return false if Connections::Gmail.connected?(channel) || Connections::Microsoft.connected?(channel)

        imap_identity(channel).nil?
      end

      # 体験中に確かめ直す(開始画面を開いたとき。TrialState)。体験の identity に含まれる IMAP の受信箱で、ログインの記録が
      # 今の設定と合わない(パスワードを変えたなど)ものだけを、試行の上限つきで確かめる。identity はパスワードを含まないので、
      # 確かめられれば次の判定から allowed? が戻る。
      def self.recheck!(inbox, trial)
        channel = inbox.channel
        rule = imap_identity(channel)
        return unless rule && !ImapVerification.recorded?(channel) && trial.identities.exists?(digest(*rule))

        ImapVerification.verified?(channel)
      end

      # IMAP で受信している標準メール受信箱(IMAP 有効・ログインあり)。転送だけの受信箱(IMAP 無効)は含めない。
      # Instagram など再認証を持つ他の窓口は Channel::Email ではないので含めない(imap_enabled を持たない)。
      # 体験の対象はこのうち規則に合い確かめられたもの。ガイド(OnboardingInboxes#mail_usable?)は imap_identity の規則で数える
      # (実認証はしない)。
      def self.imap_mailbox?(channel)
        channel.is_a?(Channel::Email) && channel.imap_enabled == true && ImapVerification.filled?(channel.imap_login.to_s.strip)
      end

      # identity に使うメールアドレス。小文字にし、局所部とドメインの前後の空白(全角の空白・NBSP などを含む)と、ドメインの
      # 末尾のドットを除く(ホストの ImapVerification.host と同じく user@gmail.com. = user@gmail.com)。Gmail と googlemail.com は
      # 局所部のドットと + 以降も除く(局所部が空になるアドレスは対象外)。
      def self.normalized_email(value)
        local, domain = value.to_s.downcase.split('@', 2)
        local = local.to_s.gsub(/\A[[:space:]]+|[[:space:]]+\z/, '')
        domain = domain.to_s.gsub(/\A[[:space:]]+|[[:space:].]+\z/, '')
        return unless ImapVerification.filled?(local) && ImapVerification.filled?(domain)
        return "#{local}@#{domain}" unless %w[gmail.com googlemail.com].include?(domain)

        name = local.split('+').first.to_s.delete('.')
        "#{name}@gmail.com" if ImapVerification.filled?(name)
      end

      # 体験中の予約・返信・受信箱の状態表示から呼ばれる。有効な体験が無い店舗では identity を作らず、IMAP の受信箱は
      # ログインの記録だけで判定する(どちらの場合も接続しない)。
      def self.allowed?(account, inbox)
        trial = Toybaco::GrowthTrial.find_by(account_id: account.id)
        return false unless trial && !trial.completed_at && trial.ends_at > Time.now.utc

        identity = recorded_identity(inbox)
        !identity.nil? && trial.identities.exists?(identity)
      end
    end
  end
end
