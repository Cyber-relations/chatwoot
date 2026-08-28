# frozen_string_literal: true

# Chatwoot commit 後の権限付与・再有効化を再試行可能にする。
# 権限剥奪は model の before_* callback で同期実行し、この job だけには委ねない。
class Toybaco::PostizMembershipJob < ApplicationJob
  queue_as :low

  retry_on Toybaco::PostizSync::Unavailable,
           Toybaco::PostizSync::NotConfigured,
           wait: :polynomially_longer,
           attempts: 12

  def perform(user_id, account_id)
    Toybaco::PostizLifecycle.reconcile_account_user!(user_id: user_id, account_id: account_id)
  end
end
