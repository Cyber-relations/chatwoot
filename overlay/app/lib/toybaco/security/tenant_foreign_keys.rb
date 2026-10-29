# frozen_string_literal: true

# request body の外部キーを店舗(account)の中に閉じる(CASA 3.1.4、2026-10-28)。
# 固定 upstream は path の id を Current.account から引くが、body で受けた担当者・チーム・カテゴリー・関連記事・
# ヘルプセンター・受信箱・受信箱の担当者の id は店舗を照合せずに保存し、応答で他店舗の名前やメールを返す経路がある。
# 作成・更新・一括処理のどの経路も同じモデルの保存を通るので、validation で止める(API は RecordInvalid の 422、
# 一括処理の job は save が false を返してその会話を変えず、記録に残す)。照合は外部キーか店舗の側の列が変わる保存
# だけで行い、既存の行のほかの列の保存は妨げない。bot の担当(assignee_agent_bot_id)は別の列で、ここでは見ない。
# 自動化・マクロの action_params の id は Toybaco::Security::TenantActionParams で閉じる。
module Toybaco::Security::TenantForeignKeys
  # model => [[外部キーの列, 店舗の側の列, 同じ店舗にあるかを返す lambda(record, id)], ...]
  RULES = {
    'Conversation' => [
      [:assignee_id, :account_id, ->(record, id) { AccountUser.exists?(account_id: record.account_id, user_id: id) }],
      [:team_id, :account_id, ->(record, id) { Team.exists?(id: id, account_id: record.account_id) }]
    ],
    'Article' => [
      [:category_id, :account_id, ->(record, id) { Category.exists?(id: id, account_id: record.account_id) }],
      [:associated_article_id, :account_id, ->(record, id) { Article.exists?(id: id, account_id: record.account_id) }]
    ],
    'Category' => [
      [:parent_category_id, :account_id, ->(record, id) { Category.exists?(id: id, account_id: record.account_id) }],
      [:associated_category_id, :account_id, ->(record, id) { Category.exists?(id: id, account_id: record.account_id) }]
    ],
    'InboxMember' => [
      [:user_id, :inbox_id, ->(record, id) { record.inbox.present? && AccountUser.exists?(account_id: record.inbox.account_id, user_id: id) }]
    ],
    'Inbox' => [[:portal_id, :account_id, ->(record, id) { Portal.exists?(id: id, account_id: record.account_id) }]],
    'Webhook' => [[:inbox_id, :account_id, ->(record, id) { Inbox.exists?(id: id, account_id: record.account_id) }]],
    'Integrations::Hook' => [[:inbox_id, :account_id, ->(record, id) { Inbox.exists?(id: id, account_id: record.account_id) }]]
  }.freeze

  def self.install!
    RULES.each_key do |name|
      model = name.constantize
      model.include(Validation) unless model < Validation
    end
    Conversation.include(TeamSentinel) unless Conversation < TeamSentinel
    BulkActionsJob.prepend(BulkRejections) unless BulkActionsJob < BulkRejections
  end

  module Validation
    extend ActiveSupport::Concern

    included do
      validate :toybaco_tenant_foreign_keys
    end

    private

    def toybaco_tenant_foreign_keys
      RULES.fetch(self.class.base_class.name).each do |column, anchor, same_store|
        id = self[column]
        next if id.blank? || !(will_save_change_to_attribute?(column) || will_save_change_to_attribute?(anchor))

        errors.add(column, :invalid) unless same_store.call(self, id)
      end
    end
  end

  # 一括処理の画面はチームの「なし」を team_id 0 で送る(upstream BulkTeamActions.vue、useBulkActions.js)。
  # 照合の前に nil にして、チームの解除を他店舗のチームの指定として拒まないようにする。
  module TeamSentinel
    extend ActiveSupport::Concern

    included do
      before_validation :toybaco_unassign_team_sentinel
    end

    private

    def toybaco_unassign_team_sentinel
      self.team_id = nil if team_id&.zero? && will_save_change_to_team_id?
    end
  end

  # upstream は先に全会話のラベルを削除し、会話ごとにラベル追加・fields の更新を別保存する。
  # 同じ transaction 内で複数回保存すると commit callback に最後の保存の差分しか渡らず、ラベルの通知・活動履歴が欠ける。
  # bulk_update を置き換え、行ロック下で最新状態を読み、ラベル削除・追加と fields の最終状態を一度だけ保存し、拒否時は何も保存しない。
  # 読み込み後に削除された会話は、ロック取得時に記録して飛ばす。
  # 応答は enqueue 時の 200 のままなので、拒まれた会話を店舗と会話の id と列の名前だけで記録に残す(他店舗の id や名前は出さない)。
  module BulkRejections
    def bulk_update
      bulk_conversation_update
    end

    def bulk_conversation_update
      params = available_params(@params)
      records.each do |conversation|
        conversation.transaction do
          next unless lock_bulk_target(conversation)

          assign_bulk_labels(conversation)
          bulk_snoozed_until(conversation)
          conversation.assign_attributes(params) if params
          raise ActiveRecord::Rollback unless conversation.save
        end
      end
      log_bulk_rejections
    end

    private

    def lock_bulk_target(conversation)
      conversation.lock!
    rescue ActiveRecord::RecordNotFound
      Rails.logger.info('[Toybaco::TenantForeignKeys] bulk update skipped deleted conversation ' \
                        "account_id=#{@account.id} conversation_id=#{conversation.id}")
      false
    end

    def assign_bulk_labels(conversation)
      return unless @params[:labels]

      labels = conversation.label_list
      labels -= @params[:labels][:remove] if @params[:labels][:remove]
      labels += Array(@params[:labels][:add]) if @params[:labels][:add]
      conversation.label_list = labels
    end

    def log_bulk_rejections
      records.to_a.select { |conversation| conversation.errors.any? }.each do |conversation|
        Rails.logger.warn("[Toybaco::TenantForeignKeys] bulk update rejected account_id=#{@account.id} " \
                          "conversation_id=#{conversation.id} attributes=#{conversation.errors.attribute_names.join(',')}")
      end
    end
  end
end
