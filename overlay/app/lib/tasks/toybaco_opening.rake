# frozen_string_literal: true

namespace :toybaco do
  desc '新規開通の未完状態を最小IDだけで確認する。店舗作成と初回案内完了は別に扱う'
  task opening_attention: :environment do
    Toybaco::OpeningRequest.order(:id).limit(100).each do |request|
      notice = Toybaco::OpeningNotice.where(opening_request_id: request.id).order(:id).last
      puts JSON.generate(id: request.id, mode: request.mode, state: request.state, attempts: request.attempts,
                         account_id: request.account_id, onboarding_state: request.onboarding_state,
                         industry_state: request.industry_state, inbox_state: request.inbox_state, notice: notice&.state)
    end
  end
end
