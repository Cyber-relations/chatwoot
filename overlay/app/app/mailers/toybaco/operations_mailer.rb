# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/opening_operations'

# 運営の通知先へ送る開通の状況(完了・確認が必要)。本文は Growth::OpeningOperations が組み立てる。
# digest は運営日次ダイジェスト(Toybaco::Ops::Digest)で、本文の組み立ては Ops::Digest が行う。
class Toybaco::OperationsMailer < ApplicationMailer
  # 配送の失敗を包み直した例外。文は固定の語と元の例外の class 名・SMTP の 3 桁の code だけ(宛先・本文・応答の文を載せない)。
  DeliveryFailed = Class.new(StandardError)
  # ApplicationMailer は Net::SMTPSyntaxError だけを handle_smtp_exceptions に回す(ExceptionList::SMTP_EXCEPTIONS)。
  # 宛先を拒否する 5xx(Net::SMTPFatalError)などの応答の文にも宛先が載るため、net-smtp の SMTP の例外をすべて回す。
  SMTP_ERRORS = [Net::SMTPAuthenticationError, Net::SMTPServerBusy, Net::SMTPSyntaxError, Net::SMTPFatalError,
                 Net::SMTPUnknownError, Net::SMTPUnsupportedCommand].freeze

  # deliver_later の job の引数(宛先・本文)を ActiveJob のログと job の payload に出さない(Toybaco::OperationsMailDeliveryJob)。
  self.delivery_job = Toybaco::OperationsMailDeliveryJob
  rescue_from(*SMTP_ERRORS, with: :handle_smtp_exceptions)

  # To は enqueue の時に選んだ主宛先(params の to)。2 本目の宛先は job の引数に載せず、配送時に toybaco_envelope が Bcc で足す
  # (主宛先が無ければ 2 本目を To にする)。どちらも無ければ何も送らない(NullMail)。
  def notice
    addresses = toybaco_envelope(params.fetch(:to))
    return unless addresses

    @body = params.fetch(:body)
    mail(**addresses, subject: params.fetch(:subject)) do |format|
      format.text { render 'toybaco/operations_mailer/notice', layout: false }
    end
  end

  # 宛先は job の引数に載せず(ActiveJob の enqueue・perform のログに運営のメールアドレスを出さない)、
  # 配送時に OpeningOperations.recipient で決める(主宛先を To、2 本目を Bcc)。宛先が無ければ mail を呼ばず、何も送らない(NullMail)。
  # LOG_LEVEL=debug では ActionMailer が配送したメールの全文(To ヘッダを含む)をログに書くため、宛先が出る。
  # 本番は LOG_LEVEL を渡さず(infra/terraform/ecs.tf)、Chatwoot の production の既定 info で動かす。
  def digest
    addresses = toybaco_envelope(Toybaco::Growth::OpeningOperations.recipient)
    unless addresses
      Rails.logger.warn('TOYBACO_OPS_DIGEST_SKIPPED reason=recipient')
      return
    end

    @body = params.fetch(:body)
    mail(**addresses, subject: params.fetch(:subject)) do |format|
      format.text { render 'toybaco/operations_mailer/notice', layout: false }
    end
  end

  private

  # 主宛先を To、2 本目(OpeningOperations::SECONDARY_ENV。同じ規則で選ぶ)を Bcc にする。同じ宛先なら 1 つにまとめ、
  # 主宛先が無ければ 2 本目を To にする。どちらも無ければ nil。
  def toybaco_envelope(primary)
    operations = Toybaco::Growth::OpeningOperations
    addresses = [primary, operations.recipient(ENV, operations::SECONDARY_ENV)].compact.uniq
    { to: addresses.first, bcc: addresses.second }.compact if addresses.any?
  end

  # 送信の失敗を握りつぶさず、Sidekiq の再試行に任せる(投げ直す)。SMTP の応答の文(宛先を含みうる)は Sidekiq の例外 handler の
  # WARN と retry set の error_message に載るため、固定の文の DeliveryFailed に包み、元の例外は cause にも残さない。
  def handle_smtp_exceptions(error)
    reply = error.respond_to?(:response) && error.response ? error.response.status : error.message
    code = reply.to_s[/\A[2-5]\d\d(?!\d)/]
    raise DeliveryFailed, ['operations mail delivery failed', error.class.name, code].compact.join(' '), cause: nil
  end
end
