# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/trial_notice'
require_relative '../../../lib/toybaco/growth/renewal_transition'
require_relative '../../../lib/toybaco/growth/free_return_record'
require_relative '../../../lib/toybaco/growth/renewal_free_notice'

class Toybaco::GrowthRenewalMailer < ApplicationMailer
  def reminder(account_id, user_id, stage, deadline)
    @account = Account.find(account_id)
    owner = Toybaco::Growth::TrialNotice.owner(@account)
    raise 'renewal notice recipient changed' unless @account.active? && owner&.id == user_id
    raise 'renewal notice stage invalid' unless %w[initial expired].include?(stage)

    @deadline = Time.iso8601(deadline).in_time_zone('Asia/Tokyo').strftime('%Y年%-m月%-d日 %-H:%M')
    @headline = stage == 'expired' ? 'お支払いの確認期限を過ぎました' : '更新のお支払いをご確認ください'
    @url = "#{ENV.fetch('FRONTEND_URL').delete_suffix('/')}/toybaco/billing?account_id=#{@account.id}"
    mail(from: ENV.fetch('MAILER_SENDER_EMAIL'), to: owner.email, subject: "【トイバコ】#{@headline}") do |format|
      format.text { render 'toybaco/growth_renewal_mailer/reminder', layout: false }
      format.html { render 'toybaco/growth_renewal_mailer/reminder', layout: false }
    end
  end

  # The store returned to Free after its renewal failure (Growth::RenewalFreeNotice). The recipient, the
  # transition and the Free contract are checked again here: a purchase after the claim raises, and the
  # notice stays uncertain. The body has no amount, card or Stripe ID.
  def free_transition_notice(account_id, user_id, transition_id)
    @account = Account.find(account_id)
    owner = Toybaco::Growth::TrialNotice.owner(@account)
    raise 'renewal notice recipient changed' unless @account.active? && owner&.id == user_id

    free_transition_details(current_free_transition(transition_id))
    @headline = 'お支払いが確認できなかったため無料プランへ移行しました'
    mail(from: ENV.fetch('MAILER_SENDER_EMAIL'), to: owner.email, subject: "【トイバコ】#{@headline}") do |format|
      format.text { render 'toybaco/growth_renewal_mailer/free_transition_notice', layout: false }
      format.html { render 'toybaco/growth_renewal_mailer/free_transition_notice', layout: false }
    end
  end

  private

  # The same completed transition, with the store still on Free (a purchase after the claim raises here).
  def current_free_transition(transition_id)
    journal = Toybaco::Entitlements.attributes(@account)[Toybaco::Growth::RenewalTransition::KEY]
    raise 'free transition changed' unless journal.is_a?(Hash) && journal['id'] == transition_id && journal['state'] == 'free_completed'
    raise 'store is no longer on Free' unless Toybaco::Growth::RenewalFreeNotice.still_free?(@account)

    journal
  end

  # The Free limits the store received in this transition, the connections the return held (its retention
  # plan) and the plan it left (the journal's source contract).
  def free_transition_details(journal)
    @limits = free_limits(journal['id'])
    plan = journal['retention'].is_a?(Hash) ? journal['retention']['plan'] : nil
    @held_inboxes = held_count(plan, 'inboxes')
    @held_posting_accounts = held_count(plan, 'posting_accounts')
    source = journal['binding'].is_a?(Hash) ? journal['binding']['source'] : nil
    @previous_plan = source['name'] if source.is_a?(Hash) && source['name'].is_a?(String) && !source['name'].empty?
    @url = "#{ENV.fetch('FRONTEND_URL').delete_suffix('/')}/toybaco/billing?account_id=#{@account.id}"
  end

  # The Free contract of the transition's receipt, not the current contract.
  def free_limits(transition_id)
    receipt = Toybaco::Growth::FreeReturnRecord.current(@account)
    raise 'free return receipt changed' unless receipt.is_a?(Hash) && receipt['transition_id'] == transition_id

    contract = receipt['free_contract']
    limits = contract.is_a?(Hash) && contract['entitlements'].is_a?(Hash) ? contract['entitlements']['limits'] : nil
    raise 'free return limits invalid' unless limits.is_a?(Hash)

    limits.slice('inboxes', 'posting_accounts', 'ai_generations')
  end

  def held_count(plan, kind)
    held = plan.is_a?(Hash) && plan[kind].is_a?(Hash) ? plan[kind]['hold'] : nil
    held.is_a?(Array) ? held.size : 0
  end

  def handle_smtp_exceptions(error)
    raise error
  end
end
