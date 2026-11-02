# frozen_string_literal: true

# PUT /auth/password(upstream の DeviseOverrides::PasswordsController#update)は、token の digest で利用者を引き、間で何も
# 押さえずにパスワードを設定して token を消す。発行からの時間も見ない(7 時間前の token も、1 年前の token も通る)。同じ token の
# 要求が同時に 2 本来ると、両方が成功して両方に session が出る。この module は private の reset_password_and_confirmation を
# 利用者の行の lock(with_lock が行を読み直す)の中で動かし、読み直した行で次の順に確かめる。
# 1. 単回の使用: 要求の token の digest が行の reset_password_token と一致すること。lock を待つ間に先の要求が使った token、
#    新しい申し込みで置き換わった token は外れる。
# 2. 期限: 発行から期限の内であること。
# どちらかが外れれば、未知の token と同じ 422(Invalid token)で返し、行には何も書かず(token は残し、新しいメールで置き換わる)、
# session も出さない。確認のリンクの Toybaco::Security::SingleUseConfirmation(#600)と同じ形。
# - 確認済みの利用者(パスワードの再設定、開通時のパスワード設定)は Devise の reset_password_within(upstream の 6 時間)。
# - 未確認の利用者には、この token が利用開始のリンクになる(担当者の招待メールのリンクはこれだけ)。利用開始のリンクの期限
#   confirm_within(24 時間)を当てる。
# 期限内の token で、未確認の利用者の確認の期限(confirmation_sent_at から 24 時間)が過ぎていれば、パスワードの設定と同時に
# 確認する。token は利用者のメールアドレスに送ったもので、期限内であることを先に確かめているので、確認のリンクと同じだけ
# メールの受け取りを示す。upstream のままでは確認だけが期限切れで失敗し、パスワードだけが設定された未確認の利用者が残って
# ログインできない。確認とパスワードの設定は同じ lock の transaction で書くので、パスワードが要件を満たさず保存されなければ
# 確認もしない。
module Toybaco::Security::PasswordResetExpiry
  def self.usable?(user)
    sent_at = user.reset_password_sent_at
    sent_at.present? && sent_at.utc >= window(user).ago.utc
  end

  def self.window(user)
    return user.class.reset_password_within if user.confirmed?

    user.class.confirm_within || user.class.reset_password_within
  end

  def self.confirmation_expired?(user)
    !user.confirmed? && user.send(:confirmation_period_expired?)
  end

  private

  def reset_password_and_confirmation(recoverable)
    digest = Devise.token_generator.digest(self, :reset_password_token, params[:reset_password_token])
    recoverable.with_lock do
      next false unless ActiveSupport::SecurityUtils.secure_compare(recoverable.reset_password_token.to_s, digest.to_s)
      next false unless Toybaco::Security::PasswordResetExpiry.usable?(recoverable)

      recoverable.skip_confirmation! if Toybaco::Security::PasswordResetExpiry.confirmation_expired?(recoverable)
      super
    end
  end
end
