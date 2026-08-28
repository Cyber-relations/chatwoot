# frozen_string_literal: true

# CE-only の公式 Chatwoot 本体を fork せず、overlay だけで所属変更を Postiz へ伝える。
# to_prepare は development の reload にも対応し、include 済み確認で callback 重複を防ぐ。
Rails.application.config.to_prepare do
  AccountUser.include(Toybaco::PostizLifecycle::AccountUserHooks) unless
    AccountUser < Toybaco::PostizLifecycle::AccountUserHooks
  Account.include(Toybaco::PostizLifecycle::AccountHooks) unless
    Account < Toybaco::PostizLifecycle::AccountHooks
  User.include(Toybaco::PostizLifecycle::UserHooks) unless
    User < Toybaco::PostizLifecycle::UserHooks
end
