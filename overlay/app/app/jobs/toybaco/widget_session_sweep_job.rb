# frozen_string_literal: true

# Only expired authorization state is removed. ContactInbox, Contact and
# Conversation rows are not children of these tables and are never deleted.
class Toybaco::WidgetSessionSweepJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    now = Time.current
    Toybaco::WidgetSessionRecord.transaction do
      sessions = Toybaco::WidgetSessionRecord.where('expires_at <= ?', now)
      ids = sessions.order(:id).limit(500).lock('FOR UPDATE SKIP LOCKED').pluck(:id)
      sessions.where(id: ids).delete_all
    end

    Toybaco::WidgetHandoff.transaction do
      grants = Toybaco::WidgetHandoff.where('expires_at <= ?', now)
      grants = grants.where('cookie_expires_at IS NULL OR cookie_expires_at <= ?', now)
      ids = grants.order(:id).limit(500).lock('FOR UPDATE SKIP LOCKED').pluck(:id)
      grants.where(id: ids).delete_all
    end
  end
end
