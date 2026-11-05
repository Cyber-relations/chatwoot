# frozen_string_literal: true

# Widget uploads authenticate with the HttpOnly HTTP session and its proof (main
# since #504; a legacy widget JWT grants no authority after the widget cutover).
module ToybacoWidgetUploadHelper
  def widget_upload_headers(widget, link)
    host! 'chatwoot.test'
    https!
    secret = SecureRandom.hex(32)
    row = widget_upload_session(link, secret)
    session = Toybaco::Security::WidgetHttpSession.new(row)
    cookies[Toybaco::Security::WidgetHttpSession.cookie_name(widget)] = "#{row.id}.#{secret}"
    { 'Origin' => 'https://chatwoot.test', 'X-Toybaco-Widget' => '1', 'Sec-Fetch-Site' => 'same-origin', 'X-Auth-Token' => session.proof }
  end

  private

  def widget_upload_session(link, secret)
    sessions = Toybaco::Security::WidgetHttpSession
    Toybaco::WidgetSessionRecord.create!(
      contact_inbox: link, inbox_id: link.inbox_id, secret_digest: sessions.digest(secret), link_digest: sessions.link_digest(link),
      bootstrap_digest: SecureRandom.hex(32), bootstrap_expires_at: 1.minute.from_now,
      rotated_at: Time.current, expires_at: 30.days.from_now, persisted_at: Time.current
    )
  end
end
