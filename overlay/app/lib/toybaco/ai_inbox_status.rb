# frozen_string_literal: true

require_relative 'ai_reply_mode'
require_relative 'ai_usage'
require_relative 'growth/bot_access'
require_relative 'growth/managed_auto'
require_relative 'growth/usage_summary'

# What AI does in each inbox when a new message arrives, for the composer bar (owner ruling, 2026-10-06): auto
# replies by itself, draft leaves a draft note that a person sends, off does nothing. Each answer follows the
# sender (bot/handler.py, BotReply#reserve_current, ManagedAutoIngress#admit, ReplyPolicy#automatic). Drafts made
# on request from the reply box are the panel's business, not this line's.
module Toybaco::AiInboxStatus
  OFF = 'off'
  DRAFT = 'draft'
  AUTO = 'auto'
  NOT_ASSIGNED = 'この窓口には AI が割り当てられていません'
  SUSPENDED = '利用停止中'
  AI_DISABLED = 'AI返信はご契約に含まれていません'
  TERMS_UNKNOWN = '利用条件を確認できません'
  STORE_DRAFT = '店舗全体の設定が下書きのため、新着には返信しません'
  FACTS_REQUIRED = '店舗情報が未確認です'
  PAUSED = '自動応答の受付停止中'
  AUTOMATIC_USED_UP = '自動応答に使える回数が残っていません'
  MANAGED_INELIGIBLE = '自動応答の条件が揃っていません'
  QUOTA_USED = '今月の AI 枠を使い切りました'
  TRIAL_DENIALS = { 'trial_not_started' => '自動応答の体験が始まっていません', 'trial_ended' => '自動応答の体験は終了しました',
                    'connection_not_covered' => '体験の対象外の窓口です' }.freeze
  MANAGED_STATES = { 'draft' => '自動応答は準備済みで、まだ返信しません', 'stopping' => '停止処理中', 'stopped' => '停止済み' }.freeze

  module_function

  def for_account(account)
    Reader.new(account).read
  end

  class Reader
    MANAGED = Toybaco::Growth::ManagedAuto
    BOT = Toybaco::Growth::BotAccess
    # A contract the plan catalog cannot read gives no allowance and no reason.
    UNREADABLE = { 'enabled' => false, 'reason' => nil }.freeze

    def initialize(account)
      @account = account
      @mode = Toybaco::AiReplyMode.read_from(account)
    end

    def read
      { 'mode' => @mode, 'inboxes' => @account.inboxes.order(:id).map { |inbox| entry(inbox) } }
    end

    private

    # The third value marks an inbox that would answer but for the month's allowance; the line then says it stopped.
    def entry(inbox)
      status, reason, used = closed || managed_status(inbox) || bot_status(inbox) || [OFF, NOT_ASSIGNED]
      reason = QUOTA_USED if used
      { 'id' => inbox.id, 'name' => inbox.name, 'status' => status, 'reason' => reason, 'quota_used' => used == true }
    end

    # The store-wide stops the composer showed before this line (aiModeCompactStatus: account_inactive and
    # disabled from /toybaco/ai_usage). The senders refuse both: the reservation needs an active account and an allowance.
    def closed
      return [OFF, SUSPENDED] unless @account.active?

      [OFF, AI_DISABLED] if usage['enabled'] != true && usage['reason'] == 'disabled'
    end

    # ManagedAutoIngress#admit answers only for an auto installation, with the feature on, the store on auto and an
    # eligible contract (facts confirmed among others); a prepared one only opens the conversation.
    def managed_status(inbox)
      row = installation
      return unless row && row.inbox_id == inbox.id && MANAGED.current_assignment?(row)
      return [OFF, MANAGED_STATES.fetch(row.state, row.state.to_s)] unless row.state == 'auto'
      return [OFF, TERMS_UNKNOWN] unless ai_available?

      managed_auto_status
    end

    def managed_auto_status
      return [OFF, PAUSED] unless MANAGED.enabled?
      return [OFF, STORE_DRAFT] unless auto_mode?
      return [OFF, FACTS_REQUIRED] if facts_required?
      return [OFF, MANAGED_INELIGIBLE] unless MANAGED.eligible?(@account)

      [AUTO, nil, quota_used?]
    end

    # A legacy store's bot answers without asking Rails once the store is listed for it (ALLOWED_ACCOUNT_IDS, set up
    # together with this assignment): it replies in auto mode and leaves a draft note in draft mode.
    def bot_status(inbox)
      return unless bot_inbox_ids.include?(inbox.id)
      return [OFF, TERMS_UNKNOWN] unless ai_available?
      return [auto_mode? ? AUTO : DRAFT, nil, quota_used?] unless growth?

      growth_bot_status(inbox)
    end

    # On a growth contract the bot drafts nothing on arrival: in draft mode it only opens the conversation. In auto
    # mode it replies when BotAccess allows this inbox (feature flag, then BotAccess.rights?) and
    # BotReply#reserve_current reserves an automatic reply (store facts confirmed, an automatic allowance left).
    def growth_bot_status(inbox)
      return [OFF, STORE_DRAFT] unless auto_mode?

      refusal = growth_refusal(inbox)
      return [OFF, refusal] if refusal
      return [AUTO, nil] if usage['automatic_enabled'] == true

      # With automatic replies in the contract the automatic allowance is the month's allowance (AiLedger#allowed_sources).
      quota_used? && BOT.included?(@account) ? [AUTO, nil, true] : [OFF, AUTOMATIC_USED_UP]
    end

    # In the order the bot meets them: BotAccess.read (feature flag, then rights), then BotReply#reserve_current.
    def growth_refusal(inbox)
      return PAUSED unless BOT.enabled?
      return trial_denial unless BOT.rights?(@account, inbox)

      FACTS_REQUIRED if facts_required?
    end

    def trial_denial
      TRIAL_DENIALS.fetch(BOT.trial_denial(@account, Time.now.utc), TRIAL_DENIALS['connection_not_covered'])
    end

    # Disabled and suspended stores are closed above; what is left unavailable are terms nobody can confirm.
    def ai_available?
      usage['enabled'] == true
    end

    def auto_mode?
      @mode == Toybaco::AiReplyMode::AUTO
    end

    # ReplyPolicy#automatic (merged into UsageSummary#read) names unconfirmed store facts.
    def facts_required?
      usage['automatic_reason'] == 'facts_required'
    end

    def quota_used?
      usage['enabled'] == true && usage['remaining'] == 0 # rubocop:disable Style/NumericPredicate
    end

    # The allowance /toybaco/ai_usage reports for the store: UsageSummary on a growth contract, AiUsage otherwise.
    def usage
      @usage ||= begin
        growth? ? Toybaco::Growth::UsageSummary.new(@account).read : Toybaco::AiUsage.new(@account).summary
      rescue Toybaco::PlanCatalog::Invalid
        UNREADABLE
      end
    end

    def growth?
      return @growth if defined?(@growth)

      @growth = BOT.growth?(@account)
    end

    def installation
      return @installation if defined?(@installation)

      @installation = MANAGED::INSTALLATIONS.find_by(account_id: @account.id)
    end

    # The same assignments Toybaco::AiReadiness counts as configured.
    def bot_inbox_ids
      @bot_inbox_ids ||= AgentBotInbox.where(account_id: @account.id, status: :active).joins(:inbox, :agent_bot)
                                      .where(inboxes: { account_id: @account.id }, agent_bots: { account_id: [nil, @account.id] })
                                      .where("NULLIF(TRIM(agent_bots.outgoing_url), '') IS NOT NULL").distinct.pluck(:inbox_id)
    end
  end
end
