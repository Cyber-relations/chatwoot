# frozen_string_literal: true

# 自動化ルール・マクロの action_params に入る id を店舗(account)の中に閉じる(CASA 3.1.4、2026-10-29)。
# - send_email_to_team: 宛先チームの id を upstream は Team.where(id:) で全店舗から引き、他店舗のチームの利用者に
#   メールを送れた(automation_rules/action_service.rb:57-66)。保存時に同じ店舗のチームかを照合し、照合より前に
#   保存された行のために実行時も @account.teams に限る。
# - send_attachment: 添付の blob を upstream は ActiveStorage::Blob.where(id:) で全店舗から引き
#   (macros/execution_service.rb:50-64、automation_rules/action_service.rb:25-36)、保存時の照合
#   (attachment_concern.rb:22-34)は先頭の 1 件しか見ないので、他店舗の blob を自店舗の message に添付できた。
#   実行時に、そのルール・マクロ自身に付いた file の blob に限る。
module Toybaco::Security::TenantActionParams
  def self.install!
    AutomationRule.include(EmailTeamRecipients) unless AutomationRule < EmailTeamRecipients
    AutomationRules::ActionService.prepend(RuleExecution) unless AutomationRules::ActionService < RuleExecution
    Macros::ExecutionService.prepend(MacroExecution) unless Macros::ExecutionService < MacroExecution
  end

  module EmailTeamRecipients
    extend ActiveSupport::Concern

    included do
      before_validation :toybaco_normalize_email_team_ids, if: -> { will_save_change_to_actions? || will_save_change_to_account_id? }
      validate :toybaco_email_team_recipients, if: -> { will_save_change_to_actions? || will_save_change_to_account_id? }
    end

    private

    # 編集画面で宛先欄を触らないと team_ids は [{ id: ..., name: ... }] のまま届く。
    # 保存・実行で使う値も整数に揃え、不正な要素は nil として残して照合で拒む。
    def toybaco_normalize_email_team_ids
      normalized = actions.as_json
      toybaco_email_team_params(normalized).each do |recipient|
        recipient['team_ids'] = Array.wrap(recipient['team_ids']).map do |team|
          id = team.is_a?(Hash) ? team['id'] : team
          case id
          when Integer then id
          when String then Integer(id, 10) if id.match?(/\A[0-9]+\z/)
          end
        end
      end
      self.actions = normalized
    end

    def toybaco_email_team_recipients
      ids = toybaco_email_team_params.flat_map { |recipient| Array.wrap(recipient['team_ids']) }
      return if ids.empty?

      own = Team.where(account_id: account_id, id: ids.compact).ids
      errors.add(:actions, :invalid) unless ids.all? { |id| own.include?(id) }
    end

    # 画面の形は [{ team_ids: [...], message: '...' }]。action_params が Hash 1 つの形も読む。
    def toybaco_email_team_params(action_list = actions.as_json)
      Array(action_list).select { |action| action.is_a?(Hash) && action['action_name'] == 'send_email_to_team' }
                        .flat_map { |action| Array.wrap(action['action_params']) }
                        .select { |recipient| recipient.is_a?(Hash) }
    end
  end

  module RuleExecution
    private

    def send_email_to_team(params)
      recipient = params&.first
      return super unless recipient.respond_to?(:merge)

      super([recipient.merge(team_ids: @account.teams.where(id: Array(recipient[:team_ids])).ids)])
    end

    def send_attachment(blob_ids)
      super(@rule.files_blobs.where(id: Array(blob_ids)).ids)
    end
  end

  module MacroExecution
    private

    def send_attachment(blob_ids)
      super(@macro.files_blobs.where(id: Array(blob_ids)).ids)
    end
  end
end
