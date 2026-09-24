# frozen_string_literal: true

class Toybaco::OpeningMailer < ApplicationMailer
  def guidance(owner)
    origin = ENV.fetch('FRONTEND_URL').delete_suffix('/')
    raise ArgumentError unless %w[https://app.toybaco.jp https://app.staging.toybaco.jp].include?(origin)

    @login_url = "#{origin}/app/login"
    @reset_url = "#{origin}/app/auth/reset/password"
    mail(to: owner.email, subject: I18n.t('toybaco.opening_mail.subject', locale: :ja)) do |format|
      format.text { render 'toybaco/opening_mailer/guidance', layout: false }
    end
  end

  private

  def handle_smtp_exceptions(error)
    raise error
  end
end
