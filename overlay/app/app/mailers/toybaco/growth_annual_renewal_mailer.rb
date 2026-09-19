# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/annual_renewal_reminder'

class Toybaco::GrowthAnnualRenewalMailer < ApplicationMailer
  def reminder(account_id, user_id, renewal, stage, deadline)
    @account = Account.find(account_id)
    owner = Toybaco::Growth::TrialNotice.owner(@account)
    raise 'annual renewal recipient changed' unless @account.active? && owner&.id == user_id
    raise 'annual renewal stage invalid' unless %w[thirty_days seven_days].include?(stage)

    verify_current_term!(renewal, deadline)
    verify_receipt!(renewal, stage, user_id)

    @deadline = Time.at(deadline).in_time_zone('Asia/Tokyo').strftime('%Y年%-m月%-d日 %-H:%M')
    @url = "#{ENV.fetch('FRONTEND_URL').delete_suffix('/')}/toybaco/billing?account_id=#{@account.id}"
    @headline = '年払い契約の更新予定'
    mail(from: ENV.fetch('MAILER_SENDER_EMAIL'), to: owner.email, subject: "【トイバコ】#{@headline}") do |format|
      format.text { render 'toybaco/growth_annual_renewal_mailer/reminder', layout: false }
      format.html { render 'toybaco/growth_annual_renewal_mailer/reminder', layout: false }
    end
  end

  private

  def verify_current_term!(renewal, deadline)
    attrs = Toybaco::Entitlements.attributes(@account)
    contract = Toybaco::Entitlements.contract_for(@account)
    valid = renewal == "#{attrs['toybaco_subscription_id']}:#{deadline}" && contract&.dig('cycle') == 'year' &&
            attrs.dig(Toybaco::Growth::PaidPeriod::KEY, 'term_end') == deadline
    raise 'annual renewal term changed' unless valid
  end

  def verify_receipt!(renewal, stage, user_id)
    receipt = Toybaco::Entitlements.attributes(@account)[Toybaco::Growth::AnnualRenewalReminder::KEY]
    valid = receipt.is_a?(Hash) && receipt['renewal'] == renewal && receipt.dig('stages', stage, 'user_id') == user_id &&
            receipt.dig('stages', stage, 'state') == 'dispatching'
    raise 'annual renewal receipt changed' unless valid
  end

  def handle_smtp_exceptions(error)
    raise error
  end
end
