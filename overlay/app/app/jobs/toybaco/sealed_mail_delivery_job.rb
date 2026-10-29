# frozen_string_literal: true

# 引数を封印して運ぶメールの配送 job。Devise のメール(再設定・確認・招待)は deliver_later で生の token を job の引数に載せる
# (User#send_devise_notification、devise の recoverable・confirmable)。ActiveJob の enqueue・perform のログは
# toybaco_log_redaction.rb で引数を出さないが、job の payload(Redis・Sidekiq の job_hash・retry / dead set・Web UI・例外 handler)
# には残るので、ActiveJob が直列化した arguments を serialize で暗号文に置き換え、deserialize で戻す。
#
# 方式は Toybaco::OperationsMailDeliveryJob と同じ(AES-256-GCM、鍵は Rails.application.key_generator に専用の salt を渡して作る。
# rails / sidekiq のタスクは同じ SECRET_KEY_BASE を受け取る)。salt と purpose は別にし、片方の暗号文をもう片方で読めない。
# SEALED の無い旧い形の payload(deploy の切り替えの間に旧 image が積んだ job)は arguments をそのまま使う。
# queue は ActionMailer::MailDeliveryJob の指定(deliver_later_queue_name)のまま。
#
# 2 段階で切り替える。旧い Sidekiq(この class の無い image)は job_class を引けず、再試行でも直らない(deploy は web を先に
# 回し、失敗時は前の task definition へ戻す)。第 1 段(この版)は読む側の class だけを配り、Devise の配送 job は変えない。
# 第 2 段は、Sidekiq と戻し先の image がこの class を読めるようになった後の release で、環境変数 SWITCH を 1 にして
# Devise のメールをこの job で積む。第 1 段でも log には token を出さない(job の引数は toybaco_log_redaction.rb の
# log_arguments=false と Sidekiq の error handler で出さない)。残るのは Redis の payload の平文だけ。
class Toybaco::SealedMailDeliveryJob < ActionMailer::MailDeliveryJob
  SEALED = 'toybaco_sealed_mail_arguments'
  VERSION = 1
  SALT = 'toybaco-sealed-mail-delivery-v1'
  PURPOSE = 'toybaco-sealed-mail-delivery'
  SWITCH = 'TOYBACO_SEALED_DEVISE_MAIL'

  self.log_arguments = false

  # Devise のメールの配送 job を、SWITCH が真のときだけこの job にする(既定は変えない)。
  def self.configure_devise!(env = ENV)
    Devise::Mailer.delivery_job = self if ActiveModel::Type::Boolean.new.cast(env[SWITCH])
  end

  # payload から ActiveJob の直列化した arguments を取り出す(SEALED が無ければ旧い形として arguments をそのまま返す)。
  # 版の違い・改ざん・鍵の違いは例外で止め、例外の文に payload の中身は載せない(Sidekiq の再試行に回る)。
  def self.unseal(job_data)
    sealed = job_data[SEALED]
    return job_data.fetch('arguments') if sealed.nil?
    raise ArgumentError, 'toybaco sealed mail arguments version' unless sealed.is_a?(Hash) && sealed['v'] == VERSION

    arguments = encryptor.decrypt_and_verify(sealed['data'], purpose: PURPOSE)
    raise ArgumentError, 'toybaco sealed mail arguments shape' unless arguments.is_a?(Array)

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
