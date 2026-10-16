# frozen_string_literal: true

module Toybaco::Security::WidgetHttpBootstrap
  def bootstrap(request, widget, legacy_token:, intent:, lock_scope: nil)
    validate_bootstrap_request(request, intent, legacy_token)

    existing = bootstrap_cookie(request, widget)
    legacy = legacy_link(widget, legacy_token)
    intent_digest = digest("bootstrap:#{widget.inbox.id}:#{intent}")
    grant = Toybaco::WidgetHandoff.find_by(code_digest: intent_digest, kind: 'bootstrap')
    require_known_bootstrap_target(grant, lock_scope) if grant
    return reconcile_bootstrap(grant, widget, intent, legacy_token, request) if grant

    return bootstrap_existing(request, widget, legacy, intent, legacy_token) if existing

    create_bootstrap(widget, legacy, intent_digest, intent, legacy_token)
  rescue ActiveRecord::RecordNotUnique
    # The losing transaction, including a new anonymous ContactInbox, rolled back.
    grant = Toybaco::WidgetHandoff.find_by!(code_digest: intent_digest, kind: 'bootstrap')
    require_known_bootstrap_target(grant, lock_scope)
    reconcile_bootstrap(grant, widget, intent, legacy_token, request)
  end

  def validate_bootstrap_request(request, intent, legacy_token)
    valid_token = legacy_token.nil? || (legacy_token.is_a?(String) && legacy_token.present? && legacy_token.bytesize <= 8192)
    raise ActiveRecord::RecordNotFound unless same_origin?(request) && intent.to_s.match?(/\A[a-f0-9]{64}\z/) && valid_token
  end

  def bootstrap_cookie(request, widget)
    read(request, widget)
  rescue ActiveRecord::RecordNotFound
    raise Toybaco::Security::WidgetHttpSession::Conflict
  end

  def create_bootstrap(widget, legacy, bootstrap_digest, intent, legacy_token)
    Toybaco::WidgetSessionRecord.transaction(requires_new: true) do
      link = legacy || widget.create_contact_inbox({})
      row = Toybaco::WidgetSessionRecord.create!(
        contact_inbox: link, inbox_id: widget.inbox.id,
        secret_digest: digest(SecureRandom.hex(32)), link_digest: link_digest(link), bootstrap_digest: bootstrap_digest,
        bootstrap_expires_at: Toybaco::Security::WidgetHttpSession::HANDOFF_TTL.from_now,
        rotated_at: Time.current, expires_at: expiry_days.days.from_now
      )
      secret = mac("bootstrap-cookie:#{row.id}:#{intent}")
      row.update!(secret_digest: digest(secret))
      record_bootstrap_intent(row, widget, intent, legacy_token)
      [new(row), secret]
    end
  end
end
