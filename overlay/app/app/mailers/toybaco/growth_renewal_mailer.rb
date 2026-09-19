# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/trial_notice'

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

  private

  def handle_smtp_exceptions(error)
    raise error
  end
end
