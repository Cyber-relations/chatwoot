# frozen_string_literal: true

require_relative '../billing_access'
require_relative 'ai_grants'
require_relative 'trial_connection'
require_relative 'trial_example'
require_relative '../ai_reply_mode'
require_relative '../legal_terms'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class TrialStart
      DAYS = 14
      UNITS = 100
      # 開始画面(toybaco-growth-trial.js)は160文字以内の理由をそのまま表示する。次に何をすればよいかが分かる文にする。
      MESSAGES = {
        'used_elsewhere' => '接続中の Gmail・Microsoft の受信箱に、別の店舗の体験で使ったものがあります。体験は同じ接続先につき1回です。' \
                            '元の店舗をご利用いただくか、Standard以上のプランをご検討ください。',
        'start_unconfirmed' => '開始状況を確認できませんでした。画面を更新して確認してください。',
        'account_inactive' => 'この店舗はいま利用できない状態です。サポートへお問い合わせください。',
        'email_unconfirmed' => 'メールアドレスの確認が終わってから開始できます。確認を完了して、もう一度お試しください。',
        'not_owner' => '体験を開始できるのは、この店舗の契約者です。契約者に開始を依頼してください。',
        'not_trial_plan' => '体験は、2026年9月25日改定の新料金プランの無料プラン・ライトで開始できます。' \
                            '現在のご契約では対象外です。ご契約内容をご確認ください。',
        'included' => 'このプランでは自動応答が契約に含まれています。受信箱の「AI応答」から設定してください。',
        'example_outdated' => '現在の店舗情報と最新の問い合わせで作成した回答例が必要です。画面を更新して回答例を選び直してください。' \
                              '表示されない場合は、ボット設定で「トイバコAI」を割り当てた Gmail または Microsoft の受信箱で、AIの下書きを1件作成してください。',
        'example_inbox' => '回答例を作った受信箱では体験を開始できません。体験は、トイバコで接続した Gmail または Microsoft の受信箱のうち、' \
                           'ボット設定で「トイバコAI」を割り当てたものが対象です。接続の期限が切れている場合は再接続してください。' \
                           'メールの接続は提供元の審査完了後に開放します。',
        'no_mail_inbox' => 'Gmail または Microsoft の受信箱を接続し、ボット設定で「トイバコAI」を割り当ててください。'
      }.freeze
      # 同じ接続先での再体験を止める一意索引(create_toybaco_growth_trials の migration)。同じ店舗の同時開始は店舗側の索引に当たる。
      IDENTITY_INDEX = 'toybaco_trial_external_identity'
      class Unavailable < StandardError; end

      def initialize(account, user, now: Time.now.utc)
        @account = account
        @user = user
        @now = now
      end

      def start!(example_id:, revision:, confirmed:)
        @account.with_lock do
          authorize!
          previous = Toybaco::GrowthTrial.find_by(account_id: @account.id)
          return previous if previous

          example = example!(example_id, revision, confirmed)
          identities = identities!(example)
          create!(example, revision, identities)
        end
      rescue ActiveRecord::RecordNotUnique => e
        raise Unavailable, MESSAGES.fetch(e.message.include?(IDENTITY_INDEX) ? 'used_elsewhere' : 'start_unconfirmed')
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
        raise Unavailable, MESSAGES.fetch('example_outdated') unless example

        example
      end

      def identities!(example)
        raise Unavailable, MESSAGES.fetch('example_inbox') unless TrialConnection.identity(example.inbox)

        identities = @account.inboxes.includes(:channel, :agent_bot_inbox).filter_map { |inbox| TrialConnection.identity(inbox) }.uniq
        raise Unavailable, MESSAGES.fetch('no_mail_inbox') if identities.empty?

        identities
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
