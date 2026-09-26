# frozen_string_literal: true

require_relative '../entitlements'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    # 契約の受信箱上限。種類を問わず店舗の全受信箱を数える(開通時に自動作成する転送用メールも 1 件)。
    module InboxLimit
      # 無料プランは「ご契約内容」の「有料プランを見る」(購入画面)から上位プランへ変えられる。
      # 新料金版(2026-09-25.1)の有料契約はアプリ内でプランを変更できないため、サポートへ案内する。
      FREE_GUIDANCE = '上位プランへの変更は「ご契約内容」の「有料プランを見る」から行えます。'
      SUPPORT_GUIDANCE = 'プランの変更やご不明な点は、サポートへお問い合わせください。'

      module_function

      # 上限に達していれば [上限, 現在の件数] を返す。上限の無い契約は nil。
      def reached(account)
        limit = Toybaco::Entitlements.for_account(account)&.dig('limits', 'inboxes')
        count = account.inboxes.count
        [limit, count] if limit && count >= limit
      end

      # 案内の分岐に使う契約のプラン。上限の数え方・到達の判定には使わない。
      def free_plan?(account)
        Toybaco::Entitlements.contract_for(account)&.dig('plan_id') == 'free'
      end

      # 上限到達は再試行では解消しないため「もう一度お試しください」とは案内しない。
      def notice(limit, count, free:)
        "このプランでは受信箱を#{limit}件まで接続できます(現在#{count}件)。#{free ? FREE_GUIDANCE : SUPPORT_GUIDANCE}"
      end
    end
  end
end
