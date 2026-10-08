# frozen_string_literal: true

require_relative '../billing_access'
require_relative 'ai_grants'
require_relative 'trial_connection'
require_relative 'trial_connection_release'
require_relative 'trial_example'
require_relative '../ai_reply_mode'
require_relative '../legal_terms'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class TrialStart
      DAYS = 14
      UNITS = 100
      # API の直接接続(Gmail / Microsoft)の名前を含む理由。IMAP で接続したメール受信箱は審査を待たずに対象なので、どの文も先に書く。
      # %<providers>s には開放済みの直接接続の名前だけを「 / 」でつないで入れる(TrialConnectionRelease。「または」を重ねない)。
      # 開放済みが無い時の文は MESSAGES に固定する(直接接続の名前を書かない)。
      PROVIDER_MESSAGES = {
        'example_outdated' => '現在の店舗情報と最新の問い合わせで作成した回答例が必要です。画面を更新して回答例を選び直してください。' \
                              '表示されない場合は、ボット設定で「トイバコAI」を割り当てた、IMAP で接続したメール受信箱' \
                              '（または %<providers>s の直接接続）で、AIの下書きを1件作成してください。',
        'example_inbox' => '回答例を作った受信箱では体験を開始できません。体験は、IMAP で接続したメール受信箱（開放済みなら %<providers>s の直接接続も）' \
                           'のうち、ボット設定で「トイバコAI」を割り当てたものが対象です。接続の期限が切れている場合は再接続してください。',
        'no_mail_inbox' => 'メール受信箱を IMAP で接続（開放済みなら %<providers>s の直接接続も可）し、ボット設定で「トイバコAI」を割り当ててください。'
      }.freeze
      # 直接接続が 1 つも開放されていない間だけ、example_inbox と no_mail_inbox の固定の文に添える。
      REVIEW_PENDING = TrialConnectionRelease::REVIEW_NOTE
      # 開始画面(toybaco-growth-trial.js)は160文字以内の理由をそのまま表示する。次に何をすればよいかが分かる文にする。
      MESSAGES = {
        'used_elsewhere' => '接続中のメール受信箱に、別の店舗の体験で使ったものがあります。体験は同じメールアドレスにつき1回です。' \
                            '元の店舗をご利用いただくか、Standard以上のプランをご検討ください。',
        'start_unconfirmed' => '開始状況を確認できませんでした。画面を更新して確認してください。',
        'account_inactive' => 'この店舗はいま利用できない状態です。サポートへお問い合わせください。',
        'email_unconfirmed' => 'メールアドレスの確認が終わってから開始できます。確認を完了して、もう一度お試しください。',
        'not_owner' => '体験を開始できるのは、この店舗の契約者です。契約者に開始を依頼してください。',
        'not_trial_plan' => '体験は、2026年9月25日改定の新料金プランの無料プラン・ライトで開始できます。' \
                            '現在のご契約では対象外です。ご契約内容をご確認ください。',
        'included' => 'このプランでは自動応答が契約に含まれています。受信箱の「AI応答」から設定してください。',
        'example_outdated' => '現在の店舗情報と最新の問い合わせで作成した回答例が必要です。画面を更新して回答例を選び直してください。' \
                              '表示されない場合は、ボット設定で「トイバコAI」を割り当てた、IMAP で接続したメール受信箱で、AIの下書きを1件作成してください。',
        # 括弧の「開放済みなら…の直接接続も」は審査の一文と重なり、合わせると160文字を超えるので、開放済みが無い時は書かない。
        'example_inbox' => '回答例を作った受信箱では体験を開始できません。体験は、IMAP で接続したメール受信箱のうち、' \
                           'ボット設定で「トイバコAI」を割り当てたものが対象です。接続の期限が切れている場合は再接続してください。' \
                           "#{REVIEW_PENDING}",
        # 回答例の受信箱が IMAP の規則に合うのに、Toybaco がログインを確かめられないとき(TrialConnection.imap_unverified?)。
        'imap_unverified' => 'メール受信箱の IMAP ログインを確認できませんでした。受信箱の設定（IMAP のホスト・ポート・ログイン・パスワード）を確認して、' \
                             'もう一度お試しください。',
        # 回答例の受信箱が体験の規則に合わない標準メール受信箱のとき(他のホストの Gmail のアドレス、転送だけの受信箱など。
        # TrialConnection.imap_rule_mismatch?)。
        'imap_rule_mismatch' => 'Gmail のアドレスは imap.gmail.com で IMAP を有効化した受信箱だけが対象です。転送だけの受信箱は対象外です。' \
                                '受信箱の接続方法を確認してください。',
        'no_mail_inbox' => '「その他のプロバイダー」で IMAP を有効化したメール受信箱を接続し、ボット設定で「トイバコAI」を割り当ててください。' \
                           "#{REVIEW_PENDING}"
      }.freeze
      # 同じ接続先での再体験を止める一意索引(create_toybaco_growth_trials の migration)。同じ店舗の同時開始は店舗側の索引に当たる。
      IDENTITY_INDEX = 'toybaco_trial_external_identity'
      class Unavailable < StandardError; end

      def initialize(account, user, now: Time.now.utc)
        @account = account
        @user = user
        @now = now
      end

      # 受信箱への接続(IMAP の実認証)は店舗のロックの外で行い、ロックの中ではネットワークに出ない。接続の前に、ロックの中と
      # 同じ確認(開始できる人と店舗か、開始済みか、回答例)をする(開始できない人の操作で受信箱の試行回数を使わない)。
      def start!(example_id:, revision:, confirmed:)
        previous = authorized_trial!
        return previous if previous

        checked = signed_in(example!(example_id, revision, confirmed))
        @account.with_lock do
          previous = authorized_trial!
          return previous if previous

          example = example!(example_id, revision, confirmed)
          create!(example, revision, identities!(checked))
        end
      rescue ActiveRecord::RecordNotUnique => e
        raise Unavailable, message(e.message.include?(IDENTITY_INDEX) ? 'used_elsewhere' : 'start_unconfirmed')
      end

      private

      def authorize!
        access = BillingAccess.permissions(@account, @user)
        refusal = refusal_for(access)
        raise Unavailable, MESSAGES.fetch(refusal) if refusal
      end

      # 開始できない理由を、これまでと同じ判定順(店舗・メール確認・契約者・プラン)で 1 つだけ返す。
      def refusal_for(access)
        return 'account_inactive' unless @account.active?
        return 'email_unconfirmed' unless @user&.confirmed?
        return 'not_owner' unless access[:can_manage_billing]

        plan_refusal
      end

      # 体験の対象は、新料金(共有AI枠)で自動応答が契約に含まれないプランだけ。
      def plan_refusal
        terms = Entitlements.for_account(@account)
        return 'not_trial_plan' unless terms&.dig('ai_meter') == GrowthTerms::METER

        'included' if terms.dig('features', 'ai_auto_reply') == true
      end

      def example!(id, revision, confirmed)
        facts = StoreFacts.new(@account).read
        valid = confirmed == true && facts['confirmed'] && facts['revision'] == revision
        example = TrialExample.new(@account).find(id, revision: revision) if valid
        raise Unavailable, message('example_outdated') unless example

        example
      end

      # 開始できる人と店舗かを確かめ(できなければ Unavailable)、開始済みの体験があれば返す。
      def authorized_trial!
        authorize!
        Toybaco::GrowthTrial.find_by(account_id: @account.id)
      end

      # 店舗のロックの外で受信箱を確かめる(TrialConnection.identity。IMAP は実際にログインし、結果は受信箱ごとのトランザクション
      # で記録される)。回答例の受信箱が対象にならなければ理由だけを返し、他の受信箱には接続しない(理由もロックの外で決める)。
      def signed_in(example)
        return { refusal: example_refusal(example.inbox) } unless TrialConnection.identity(example.inbox)

        { identities: @account.inboxes.includes(:channel, :agent_bot_inbox).to_h { |inbox| [inbox.id, TrialConnection.identity(inbox)] } }
      end

      # 店舗のロックの中の identity(接続しない)。ロックの外で確かめた受信箱のうち、ログインの記録が今の設定とまだ一致して、
      # 外の結果と同じ identity になるものだけ(TrialConnection.recorded_identity)。外で確かめた後に設定や接続が変わった受信箱と、
      # 外の確認で通らなかった受信箱(期限の過ぎた古い成功の記録しかないものなど)は含めない。
      def identities!(checked)
        raise Unavailable, message(checked[:refusal]) if checked[:refusal]

        identities = @account.inboxes.includes(:channel, :agent_bot_inbox).filter_map do |inbox|
          identity = TrialConnection.recorded_identity(inbox)
          identity if identity && checked[:identities][inbox.id] == identity
        end.uniq
        raise Unavailable, message('no_mail_inbox') if identities.empty?

        identities
      end

      # 回答例の受信箱で開始できない理由。IMAP の規則に合う受信箱なのにログインを確かめられないときは受信箱の設定の確認を、
      # 規則に合わない標準メール受信箱(他のホストの Gmail のアドレス、転送だけの受信箱など)は接続方法の確認を求める。
      # それ以外(LINE・Webチャット、開放前の API 接続など)は従来の理由。
      def example_refusal(inbox)
        return 'imap_unverified' if TrialConnection.imap_unverified?(inbox)
        return 'imap_rule_mismatch' if TrialConnection.imap_rule_mismatch?(inbox)

        'example_inbox'
      end

      # 理由の文。直接接続の名前を含む理由は、開放済みの直接接続があればその名前だけで書く(開放済みが無ければ MESSAGES の固定の文)。
      def message(key)
        released = PROVIDER_MESSAGES.key?(key) ? TrialConnectionRelease.released_providers(@account) : []
        return MESSAGES.fetch(key) if released.empty?

        format(PROVIDER_MESSAGES.fetch(key), providers: TrialConnectionRelease.label(released, ' / '))
      end

      def create!(example, revision, identities)
        trial = Toybaco::GrowthTrial.create!(account_id: @account.id, example_id: example.id, facts_revision: revision,
                                             starts_at: @now, ends_at: @now + DAYS.days)
        identities.each { |identity| trial.identities.create!(identity) }
        AiGrants.new(@account).issue!(source: 'trial', source_key: "trial:#{trial.id}", units: UNITS,
                                      starts_at: trial.starts_at, ends_at: trial.ends_at)
        AiReplyMode.write_to!(@account, AiReplyMode::AUTO)
        # 開始画面の説明と利用規約第7条の2への同意(confirmed)を、開始した契約者として残す。
        LegalTerms.record!(@account, route: 'trial', accepted_at: @now, user_id: @user.id)
        trial
      end
    end
  end
end
