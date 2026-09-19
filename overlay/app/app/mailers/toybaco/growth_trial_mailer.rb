# frozen_string_literal: true

class Toybaco::GrowthTrialMailer < ApplicationMailer
  def reminder(notice)
    @account = notice.account
    @trial = notice.trial
    @kind = notice.kind
    grant = Toybaco::GrowthAiGrant.find_by!(account_id: @account.id, source: 'trial', source_key: "trial:#{@trial.id}")
    @remaining = [grant.units - grant.used, 0].max
    @end_text = @trial.ends_at.in_time_zone('Asia/Tokyo').strftime('%Y年%-m月%-d日 %-H:%M')
    @url = "#{ENV.fetch('FRONTEND_URL').delete_suffix('/')}/toybaco/growth/trial?account_id=#{@account.id}"
    @headline = @kind == 'deadline' ? '自動応答の体験は、あと3日以内で終了します' : '自動応答の体験は、残り20回以内です'
    mail(from: ENV.fetch('MAILER_SENDER_EMAIL'), to: notice.user.email, subject: "【トイバコ】#{@headline}") do |format|
      format.text { render 'toybaco/growth_trial_mailer/reminder', layout: false }
      format.html { render 'toybaco/growth_trial_mailer/reminder', layout: false }
    end
  end

  private

  # The notice dispatcher must record an uncertain attempt, never a swallowed failure.
  def handle_smtp_exceptions(error)
    raise error
  end
end
