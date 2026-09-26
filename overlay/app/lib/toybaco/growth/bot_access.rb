# frozen_string_literal: true

require_relative 'trial_connection'
require_relative '../entitlements'
require_relative '../ai_reply_mode'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # AI bot の Lambda が、静的な店舗リストに無い店舗の受信箱へ自動応答してよいかを判定する。
    # 許可の述語は予約(BotReply)と同じ rights? だけ。reason は判定を説明する固定の英小文字で、顧客文言ではない。
    # DB flag は Lambda 経路の許可だけを閉じ、予約・窓口の全自動(店舗AI)・手動下書きには影響しない。
    module BotAccess
      FLAG = 'TOYBACO_GROWTH_BOT_ACCESS_ENABLED'

      module_function

      def enabled?
        GlobalConfigService.load(FLAG, false) == true
      end

      # 全自動の唯一の許可述語。契約に自動応答が含まれるか、有効な体験がこの受信箱の接続先を含むこと。
      def rights?(account, inbox)
        included?(account) || TrialConnection.allowed?(account, inbox)
      end

      def read(account, inbox:, bot:, now: Time.now.utc)
        reason = precondition(account, inbox, bot)
        return denied(reason) if reason
        return denied(trial_denial(account, now)) unless rights?(account, inbox)

        { 'allowed' => true, 'reason' => included?(account) ? 'included' : 'trial' }
      end

      def precondition(account, inbox, bot)
        return 'disabled' unless enabled?
        return 'not_growth' unless growth?(account)
        return 'inbox_unknown' unless inbox && inbox.account_id == account.id
        return 'bot_not_assigned' unless assigned?(bot, inbox)

        'mode_draft' unless AiReplyMode.read_from(account) == AiReplyMode::AUTO
      end

      # rights? が偽のときの説明。許可はここでは決めない。
      def trial_denial(account, now)
        trial = Toybaco::GrowthTrial.find_by(account_id: account.id)
        return 'trial_not_started' unless trial
        return 'trial_ended' if trial.completed_at || trial.ends_at <= now

        'connection_not_covered'
      end

      def growth?(account)
        account.active? && Entitlements.for_account(account)&.dig('ai_meter') == GrowthTerms::METER
      end

      # 呼出し元の bot がこの受信箱に active で割り当てられていること(どの bot かまで見る)。
      def assigned?(bot, inbox)
        bot.present? && bot.agent_bot_inboxes.where(status: :active).exists?(inbox_id: inbox.id)
      end

      def included?(account)
        Entitlements.for_account(account)&.dig('features', 'ai_auto_reply') == true
      end

      def denied(reason)
        { 'allowed' => false, 'reason' => reason }
      end
    end
  end
end
