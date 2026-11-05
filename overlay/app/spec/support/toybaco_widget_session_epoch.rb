# frozen_string_literal: true

RSpec.shared_context 'with a widget session established before the security epoch' do
  include_context 'with the widget session security cutover task'
  let(:epoch_source) { :environment }
  let(:widget) { create(:channel_widget) }
  let(:cutoff) { Time.current.change(usec: 0) }
  let(:secret) { SecureRandom.hex(32) }
  let(:victim) { create(:contact, account: widget.account, email: 'prior-visitor@example.test') }
  let(:link) { prior_binding }
  let(:row) do
    Toybaco::WidgetSessionRecord.create!(
      contact_inbox: link, inbox_id: widget.inbox.id, created_at: cutoff - 1.second,
      secret_digest: Toybaco::Security::WidgetHttpSession.digest(secret),
      link_digest: Toybaco::Security::WidgetHttpSession.link_digest(link), bootstrap_digest: SecureRandom.hex(32),
      bootstrap_expires_at: 1.minute.from_now, rotated_at: Time.current, expires_at: 30.days.from_now,
      persisted_at: cutoff - 1.second
    )
  end
  let(:proof) { http_session.proof }
  let(:recovery) { Toybaco::Security::WidgetHttpSession.recovery_token(row, expires_at: 1.hour.from_now) }
  let(:cookie_name) { Toybaco::Security::WidgetHttpSession.cookie_name(widget) }
  let(:cookie) { "#{row.id}.#{secret}" }

  before { stub_epoch(cutoff - 1.day) }

  def stub_epoch(value)
    lower_bound = epoch_source == :persisted ? cutoff - 1.day : value
    allow(Toybaco::Security::WidgetSessionSecurityEpoch).to receive(:lower_bound).and_return(lower_bound)
    run_widget_cutover(value) if epoch_source == :persisted
  end

  def http_session
    Toybaco::Security::WidgetHttpSession.new(row)
  end

  def prior_binding
    return legacy_jwt_binding if establishment == :legacy_jwt

    original = create(:contact, account: widget.account)
    binding = create(:contact_inbox, inbox: widget.inbox, contact: original)
    # Persist the result of the old cross-visitor merge. Source/stream and
    # hence the session link digest survived that unsafe contact reassignment.
    binding.update!(contact: victim)
    binding
  end

  def legacy_jwt_binding
    binding = create(:contact_inbox, inbox: widget.inbox, contact: victim)
    jwt = Widget::TokenService.new(payload: { inbox_id: widget.inbox.id, source_id: binding.source_id }).generate_token
    claims = Widget::TokenService.new(token: jwt).decode_token
    # Reproduce the persisted result of the retired JWT exchange, without
    # reintroducing that authority into the new bootstrap implementation.
    ContactInbox.find_by!(inbox_id: claims[:inbox_id], source_id: claims[:source_id])
  end
end
