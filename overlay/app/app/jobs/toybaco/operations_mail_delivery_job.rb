# frozen_string_literal: true

# 運営の通知先へのメール(Toybaco::OperationsMailer)の配送 job。開通の状況の知らせ(notice)は宛先と本文(契約者のメールアドレス・
# 店舗名・Stripe の id を含む)を job の引数に載せるため、ActiveJob の enqueue・perform のログ(既定の log_arguments は true、
# production の log level は info)に出さない。queue は ActionMailer::MailDeliveryJob の指定(deliver_later_queue_name)をそのまま使う。
#
# job の payload(Redis・Sidekiq の job_hash・retry / dead set・Web UI・例外 handler の WARN)にも平文を残さないよう、ActiveJob が
# 直列化した arguments を serialize で暗号文に置き換え、deserialize で戻す。payload の arguments は空にし、暗号文と版の印だけを
# SEALED に置く。鍵は Rails.application.key_generator(SECRET_KEY_BASE)に専用の salt を渡して作る(Growth::DraftInput と同じ形。
# rails / sidekiq / migrate のタスクは同じ SECRET_KEY_BASE を受け取る)。SEALED の無い旧い形の payload(deploy の切り替えの間に
# 旧 image が積んだ job)は arguments をそのまま使う。再試行は Sidekiq が同じ payload を積み直すので、2 回目も同じ鍵で復号する。
class Toybaco::OperationsMailDeliveryJob < ActionMailer::MailDeliveryJob
  SEALED = 'toybaco_sealed_arguments'
  VERSION = 1
  SALT = 'toybaco-operations-mail-delivery-v1'
  PURPOSE = 'toybaco-operations-mail-delivery'

  self.log_arguments = false

  # payload から ActiveJob の直列化した arguments を取り出す(SEALED が無ければ旧い形として arguments をそのまま返す)。
  # 版の違い・改ざん・鍵の違いは例外で止め、例外の文に payload の中身は載せない(Sidekiq の再試行に回る)。
  def self.unseal(job_data)
    sealed = job_data[SEALED]
    return job_data.fetch('arguments') if sealed.nil?
    raise ArgumentError, 'toybaco sealed arguments version' unless sealed.is_a?(Hash) && sealed['v'] == VERSION

    arguments = encryptor.decrypt_and_verify(sealed['data'], purpose: PURPOSE)
    raise ArgumentError, 'toybaco sealed arguments shape' unless arguments.is_a?(Array)

    arguments
  end

  def self.seal(arguments)
    { 'v' => VERSION, 'data' => encryptor.encrypt_and_sign(arguments, purpose: PURPOSE) }
  end

  def self.encryptor
    key = Rails.application.key_generator.generate_key(SALT, 32)
    ActiveSupport::MessageEncryptor.new(key, cipher: 'aes-256-gcm', serializer: JSON)
  end

  def serialize
    data = super
    data.merge('arguments' => [], SEALED => self.class.seal(data.fetch('arguments')))
  end

  def deserialize(job_data)
    super(job_data.merge('arguments' => self.class.unseal(job_data)))
  end
end
