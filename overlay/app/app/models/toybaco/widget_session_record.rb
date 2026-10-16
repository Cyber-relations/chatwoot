# frozen_string_literal: true

class Toybaco::WidgetSessionRecord < ApplicationRecord
  self.table_name = 'toybaco_widget_session_records'
  belongs_to :contact_inbox

  def current?
    state = self.class.where(id: id, revoked_at: nil).where('expires_at > ?', Time.current)
                .pick(:contact_inbox_id, :inbox_id, :link_digest)
    return false unless state == [contact_inbox_id, inbox_id, link_digest]

    link = ContactInbox.find_by(id: state[0])
    current_link?(link, state)
  end

  private

  def current_link?(link, state)
    link && link.inbox_id == state[1] &&
      link.inbox.account.active? && link.contact.account_id == link.inbox.account_id &&
      ActiveSupport::SecurityUtils.secure_compare(state[2], Toybaco::Security::WidgetHttpSession.link_digest(link))
  end
end
