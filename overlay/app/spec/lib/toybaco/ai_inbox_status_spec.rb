# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/toybaco/ai_inbox_status')

RSpec.describe Toybaco::AiInboxStatus do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }

  def status_of(target = inbox)
    described_class.for_account(account.reload)['inboxes'].find { |entry| entry['id'] == target.id }
  end

  def assign_bot(target = inbox, owner: account, url: 'https://worker.example.invalid/webhook', status: :active)
    create(:agent_bot_inbox, agent_bot: create(:agent_bot, account: owner, outgoing_url: url), inbox: target, status: status)
  end

  # The store mode is written first: with an installation present it follows the installation. Managed replies
  # belong to growth contracts, so the allowance is the growth one.
  def install(state, mode: 'draft')
    growth_usage
    Toybaco::AiReplyMode.write_to!(account, mode)
    bot = create(:agent_bot, account: account, outgoing_url: nil)
    create(:agent_bot_inbox, agent_bot: bot, inbox: inbox, status: :active)
    actor = create(:user, account: account, role: :administrator)
    Toybaco::GrowthAutoInstallation.create!(account_id: account.id, inbox_id: inbox.id, bot_id: bot.id, actor_id: actor.id,
                                            request_id: SecureRandom.uuid, epoch: SecureRandom.uuid, state: state)
  end

  def plan(id, version = '2026-09-25.1')
    terms = Toybaco::PlanCatalog.default.definition(id, version)
    Toybaco::Entitlements.apply!(account, Toybaco::Entitlements.snapshot_for(terms, cycle: 'month'))
  end

  # A legacy contract with AI replies (500 a month, Toybaco::AiUsage).
  def legacy_ai
    plan('pro', '2026-09-06.1')
  end

  def gmail_inbox
    Toybaco::Connections::Gmail.connect!(account: account, tokens: { 'access_token' => 'spec', 'refresh_token' => 'spec', 'expires_in' => 3600 },
                                         profile: { 'emailAddress' => "trial-#{SecureRandom.hex(4)}@example.test", 'historyId' => '1' })
  end

  # The growth allowance as UsageSummary#read reports it, with ReplyPolicy#automatic merged in; the bot's access flag is on.
  def growth_usage(**values)
    allow(Toybaco::Growth::BotAccess).to receive_messages(growth?: true, enabled?: true)
    read = { 'enabled' => true, 'automatic_enabled' => true, 'automatic_reason' => nil, 'remaining' => 5 }
           .merge(values.transform_keys(&:to_s))
    allow(Toybaco::Growth::UsageSummary).to receive(:new).and_return(instance_double(Toybaco::Growth::UsageSummary, read: read))
  end

  it 'reports an inbox without AI as off and returns the store mode' do
    inbox
    result = described_class.for_account(account)
    expect(result['mode']).to eq('auto')
    expect(result['inboxes']).to eq([{ 'id' => inbox.id, 'name' => 'Inbox', 'status' => 'off',
                                       'reason' => 'この窓口には AI が割り当てられていません', 'quota_used' => false }])
  end

  it 'counts only the active store or global bots with a webhook that the readiness check counts' do
    legacy_ai
    others = Array.new(3) { create(:inbox, account: account) }
    assign_bot(others[0], url: '   ')
    assign_bot(others[1], status: :inactive)
    assign_bot(others[2], owner: create(:account))
    assign_bot(owner: nil)
    expect(others.map { |target| status_of(target)['status'] }).to eq(%w[off off off])
    expect(status_of['status']).to eq('auto')
  end

  # bot/handler.py: a listed legacy store's bot replies in auto mode and leaves a draft note in draft mode.
  it 'follows the store mode on a legacy contract without consulting the growth reply policy' do
    legacy_ai
    expect(Toybaco::Growth::ReplyPolicy).not_to receive(:new)
    assign_bot
    expect(status_of).to include('status' => 'auto', 'reason' => nil)
    Toybaco::AiReplyMode.write_to!(account, 'draft')
    expect(status_of).to include('status' => 'draft', 'reason' => nil)
  end

  # bot/handler.py drafts nothing on arrival for a growth store, and in auto mode replies only once BotAccess and
  # BotReply#reserve_current let it.
  it 'reports a growth inbox as automatic only when the bot would reply, and off otherwise' do
    plan('standard')
    assign_bot
    growth_usage
    expect(status_of).to include('status' => 'auto', 'reason' => nil)
    Toybaco::AiReplyMode.write_to!(account, 'draft')
    expect(status_of).to include('status' => 'off', 'reason' => '店舗全体の設定が下書きのため、新着には返信しません')
    Toybaco::AiReplyMode.write_to!(account, 'auto')
    allow(Toybaco::Growth::BotAccess).to receive(:enabled?).and_return(false)
    expect(status_of).to include('status' => 'off', 'reason' => '自動応答の受付停止中')
    growth_usage(automatic_enabled: false, automatic_reason: 'facts_required')
    expect(status_of).to include('status' => 'off', 'reason' => '店舗情報が未確認です')
    growth_usage(automatic_enabled: false, automatic_reason: 'automatic_unavailable', remaining: 0)
    expect(status_of).to include('status' => 'auto', 'reason' => '今月の AI 枠を使い切りました', 'quota_used' => true)
  end

  # BotReply#reserve_current refuses automatic replies where BotAccess.rights? is false: on a contract without
  # automatic replies, the trial answers automatically only in the mailboxes it covers, while units remain.
  it 'reports the inboxes a trial does not cover as off, as the sender refuses them' do
    plan('light')
    Toybaco::AiReplyMode.write_to!(account, 'auto')
    growth_usage
    allow(Toybaco::Connections::Gmail).to receive(:allowed?).and_return(true)
    covered = gmail_inbox
    later = gmail_inbox
    web = create(:inbox, account: account)
    [covered, later, web].each { |target| assign_bot(target) }
    expect(status_of(covered)).to include('status' => 'off', 'reason' => '自動応答の体験が始まっていません')
    trial = Toybaco::GrowthTrial.create!(account_id: account.id, facts_revision: 'spec', example_id: 1,
                                         starts_at: 1.day.ago, ends_at: 6.days.from_now)
    trial.identities.create!(Toybaco::Growth::TrialConnection.identity(covered))
    expect(status_of(covered)).to include('status' => 'auto', 'reason' => nil)
    expect([later, web].map { |target| status_of(target) }).to all(include('status' => 'off', 'reason' => '体験の対象外の窓口です'))
    growth_usage(automatic_enabled: false, automatic_reason: 'automatic_unavailable')
    expect(status_of(covered)).to include('status' => 'off', 'reason' => '自動応答に使える回数が残っていません')
    trial.update!(completed_at: Time.current, completion_reason: 'expired')
    expect(status_of(covered)).to include('status' => 'off', 'reason' => '自動応答の体験は終了しました')
  end

  # The store-wide stops the composer showed before (aiModeCompactStatus: account_inactive, disabled).
  it 'turns every inbox off while the account is suspended' do
    legacy_ai
    assign_bot
    unassigned = create(:inbox, account: account)
    account.update!(status: :suspended)
    expect([inbox, unassigned].map { |target| status_of(target) })
      .to all(include('status' => 'off', 'reason' => '利用停止中', 'quota_used' => false))
  end

  it 'turns every inbox off on a contract without AI replies' do
    plan('light', '2026-09-06.1')
    assign_bot
    unassigned = create(:inbox, account: account)
    expect([inbox, unassigned].map { |target| status_of(target) })
      .to all(include('status' => 'off', 'reason' => 'AI返信はご契約に含まれていません'))
  end

  # ManagedAutoIngress#admit only opens the conversation for a prepared installation.
  it 'reports a prepared managed inbox as off' do
    install('draft')
    expect(status_of).to include('status' => 'off', 'reason' => '自動応答は準備済みで、まだ返信しません')
  end

  it 'reports a managed inbox as automatic only while the sender would reply' do
    install('auto', mode: 'auto')
    allow(Toybaco::Growth::ManagedAuto).to receive(:eligible?).and_return(true)
    expect(status_of).to include('status' => 'off', 'reason' => '自動応答の受付停止中')
    with_modified_env(TOYBACO_MANAGED_AUTO_ENABLED: 'true') do
      expect(status_of).to include('status' => 'auto', 'reason' => nil)
      allow(Toybaco::Growth::ManagedAuto).to receive(:eligible?).and_return(false)
      expect(status_of).to include('status' => 'off', 'reason' => '自動応答の条件が揃っていません')
      growth_usage(automatic_enabled: false, automatic_reason: 'facts_required')
      expect(status_of).to include('status' => 'off', 'reason' => '店舗情報が未確認です')
    end
  end

  it 'reports a managed inbox whose store mode is still draft as off' do
    install('auto')
    with_modified_env(TOYBACO_MANAGED_AUTO_ENABLED: 'true') do
      expect(status_of).to include('status' => 'off', 'reason' => '店舗全体の設定が下書きのため、新着には返信しません')
    end
  end

  # The database allows only draft, auto, stopping and stopped; a state added later must not read as automatic.
  it 'reports a managed state it does not know as off under its own name' do
    installation = install('auto', mode: 'auto')
    allow(Toybaco::Growth::ManagedAuto).to receive(:eligible?).and_return(true)
    installation.state = 'paused'
    allow(Toybaco::Growth::ManagedAuto::INSTALLATIONS).to receive(:find_by).and_return(installation)
    with_modified_env(TOYBACO_MANAGED_AUTO_ENABLED: 'true') do
      expect(status_of).to include('status' => 'off', 'reason' => 'paused')
    end
  end

  it 'names the stopping and stopped managed states' do
    installation = install('stopping')
    expect(status_of).to include('status' => 'off', 'reason' => '停止処理中')
    installation.update!(state: 'stopped')
    expect(status_of).to include('status' => 'off', 'reason' => '停止済み')
  end

  it 'keeps the status but explains a used-up AI allowance' do
    legacy_ai
    assign_bot
    unassigned = create(:inbox, account: account)
    Toybaco::AiReplyMode.write_to!(account, 'draft')
    allow(Toybaco::AiUsage).to receive(:new).and_return(instance_double(Toybaco::AiUsage, summary: { 'enabled' => true, 'remaining' => 0 }))
    expect(status_of).to include('status' => 'draft', 'reason' => '今月の AI 枠を使い切りました', 'quota_used' => true)
    expect(status_of(unassigned)).to include('status' => 'off', 'reason' => 'この窓口には AI が割り当てられていません', 'quota_used' => false)
  end

  # No contract at all (AiUsage: unknown_contract), or one the plan catalog cannot read: the senders refuse the
  # reservation, and the line neither fails nor promises anything.
  it 'reports off under unknown terms when nobody can confirm or read the contract' do
    assign_bot
    expect(status_of).to include('status' => 'off', 'reason' => '利用条件を確認できません')
    allow(Toybaco::AiUsage).to receive(:new).and_raise(Toybaco::PlanCatalog::Invalid)
    expect(status_of).to include('status' => 'off', 'reason' => '利用条件を確認できません')
    allow(Toybaco::Growth::BotAccess).to receive(:growth?).and_return(true)
    allow(Toybaco::Growth::UsageSummary).to receive(:new).and_raise(Toybaco::PlanCatalog::Invalid)
    expect(status_of).to include('status' => 'off', 'reason' => '利用条件を確認できません', 'quota_used' => false)
    allow(Toybaco::Growth::BotAccess).to receive(:growth?).and_raise(Toybaco::PlanCatalog::Invalid)
    expect(status_of).to include('status' => 'off', 'reason' => '利用条件を確認できません')
  end
end
