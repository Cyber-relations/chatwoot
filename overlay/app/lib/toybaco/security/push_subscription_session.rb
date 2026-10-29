# frozen_string_literal: true

# Browser push の購読を、登録したログイン(DeviseTokenAuth の client)に結び付け、そのログインが今も有効なときだけ送る
# (CASA 6.6.1)。上流の Notification::PushNotificationService はログインの有無を見ずに保存済みの購読へ送り、public/sw.js は
# 届いた通知をそのまま表示する。
#
# - 登録(Binding・BuilderGuard): 購読の subscription_attributes に client id の SHA-256(SESSION_KEY)だけを置く。client id
#   そのものは置かない。保存の直前に users の行を lock して、そのログインが今も有効かを照合する(logout と順番を揃える)。
# - 送信(Delivery): 送る直前に users の行から tokens を読み直し、結び付いたログインが残っていて期限内の購読にだけ送る。
#   結び付きの無い購読(この版より前に登録したもの・ログインの client の無い要求で登録したもの)と、logout・失効・ほかの端末
#   からの session の取り消しで消えたログインの購読には送らない。mobile の購読(fcm)は今のまま送る。
# - logout(Revocation): 同じ users の行を lock して、そのログインに結び付いた購読を消してから、上流の logout を行う。送信時の
#   照合があるので、これは掃除の最適化。
#
# この版より前の購読は、次に dashboard を開いたときに上流の App.vue(と api.js の restoreBrowserPushOnLogin)が登録し直すまで
# 届かない。browser の unsubscribe(api.js の logout の掃除)は best-effort のまま続ける。
module Toybaco::Security::PushSubscriptionSession
  SESSION_KEY = 'toybaco_session'

  # 登録の保存の直前に、そのログインが終わっていたとき。Binding が 401 にする。
  class SessionEnded < StandardError; end

  def self.digest(client)
    Digest::SHA256.hexdigest("toybaco-push-session:#{client}")
  end

  # 通常認証と同じく、DTA の期限に加えて、その client の MFA proof も現在有効でなければならない。
  def self.live?(user, session_digest, now: Time.current.to_i)
    return false if session_digest.blank? || !user&.tokens.is_a?(Hash)

    user.tokens.any? { |client, data| live_client?(user, client, data, session_digest, now) }
  end

  def self.live_client?(user, client, data, session_digest, now)
    return false unless data.is_a?(Hash) && data['expiry'].to_i > now
    return false unless ActiveSupport::SecurityUtils.secure_compare(digest(client), session_digest.to_s)

    Toybaco::Security::ApplicationMfaSession.valid?(user, client)
  end

  # 保存済みの browser push の購読に、今送ってよいか。users の行の tokens をこの場で読み直す。
  def self.deliverable?(subscription)
    session_digest = subscription.subscription_attributes.to_h[SESSION_KEY]
    return false if session_digest.blank?

    # 一つの job 内でも、前の配送中に別接続で確定した logout / MFA 変更を見落とさない。
    User.uncached { live?(User.find_by(id: subscription.user_id), session_digest) }
  end

  # 利用者の users の行を lock する(登録と logout の順番を揃える)。呼ぶ側の User の object は読み直さない。
  def self.lock_user(user_id)
    User.lock.find(user_id)
  end

  # Api::V1::NotificationSubscriptionsController に prepend する。browser push の登録に、この要求のログインの印を付ける。
  # 要求の側から送られた印は使わない(ログインの client が無い要求では印を外す)。permit 済みの値から作った Hash を
  # NotificationSubscriptionBuilder に渡す(入れ子の Parameters を作らない)。保存の直前にログインが終わっていたら 401。
  module Binding
    def create
      super
    rescue Toybaco::Security::PushSubscriptionSession::SessionEnded
      head :unauthorized
    end

    private

    def notification_subscription_params
      permitted = super
      return permitted unless permitted[:subscription_type] == 'browser_push'

      attributes = permitted[:subscription_attributes].to_h.except(SESSION_KEY)
      client = @token&.client
      attributes[SESSION_KEY] = Toybaco::Security::PushSubscriptionSession.digest(client) if client.present?
      permitted.to_h.merge('subscription_attributes' => attributes)
    end
  end

  # NotificationSubscriptionBuilder に prepend する。ログインに結び付けた browser push の登録は、users の行を lock した
  # transaction の中で、そのログインが今も有効かを照合してから上流の保存を行う。
  module BuilderGuard
    def perform
      session_digest = toybaco_session_digest
      return super if session_digest.blank?

      User.transaction do
        locked = Toybaco::Security::PushSubscriptionSession.lock_user(user.id)
        raise SessionEnded unless Toybaco::Security::PushSubscriptionSession.live?(locked, session_digest)

        super
      end
    end

    private

    def toybaco_session_digest
      return unless params[:subscription_type] == 'browser_push'

      attributes = params[:subscription_attributes]
      attributes.respond_to?(:key?) ? attributes[SESSION_KEY] : nil
    end
  end

  # Notification::PushNotificationService に prepend する。browser push は、結び付いたログインが今も有効な購読にだけ送る。
  module Delivery
    private

    def can_send_browser_push?(subscription)
      return false unless super
      return true if Toybaco::Security::PushSubscriptionSession.deliverable?(subscription)

      Rails.logger.info("Browser push skipped for subscription #{subscription.id}: no live session")
      false
    end
  end

  # DeviseOverrides::SessionsController に prepend する。DTA の set_user_by_token(destroy の before_action)が @resource と
  # @token を決めた後、users の行を lock して、logout するログインに結び付いた browser push の購読を消してから、上流の logout
  # を行う。
  module Revocation
    def destroy
      client = @token&.client
      return super unless @resource.is_a?(User) && client.present?

      User.transaction do
        # 上流 DTA が保存する object 自体を再読込する。別 object の lock だけでは古い tokens を書き戻してしまう。
        @resource.lock!
        revoke_toybaco_push_subscriptions(client)
        super
      end
    end

    private

    def revoke_toybaco_push_subscriptions(client)
      digest = Toybaco::Security::PushSubscriptionSession.digest(client)
      @resource.notification_subscriptions.browser_push
               .where("subscription_attributes->>'#{SESSION_KEY}' = ?", digest).destroy_all
    end
  end
end
