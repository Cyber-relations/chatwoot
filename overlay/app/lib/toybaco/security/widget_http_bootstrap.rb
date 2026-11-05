# frozen_string_literal: true

module Toybaco::Security::WidgetHttpBootstrap
  def bootstrap_ephemeral(request, widget, intent:)
    validate_bootstrap_request(request, intent)
    discard_cookie(request, widget)
    Toybaco::Security::WidgetSessionSecurityEpoch.with_creation_lock do
      create_ephemeral(widget)
    end
  end

  def create_ephemeral(widget)
    # Neither a cookie nor a replay alias can recover this page's new visitor.
    link = widget.create_contact_inbox({})
    row = Toybaco::WidgetSessionRecord.create!(
      contact_inbox: link, inbox_id: widget.inbox.id, link_digest: link_digest(link),
      bootstrap_digest: digest(SecureRandom.hex(32)), bootstrap_expires_at: Time.current,
      secret_digest: digest(SecureRandom.hex(32)), rotated_at: Time.current, expires_at: 2.hours.from_now
    )
    recovery_token(row, expires_at: row.expires_at)
  end

  private :create_ephemeral

  def discard_cookie(request, widget)
    revoke_cookie(request, widget)
    clear_cookie(request, widget)
  end

  def clear_cookie(request, widget)
    request.cookie_jar.delete(cookie_name(widget, secure: request.ssl?),
                              path: '/', secure: request.ssl?, httponly: true,
                              same_site: request.ssl? ? :none : :lax, partitioned: request.ssl?)
  end

  def revoke_cookie(request, widget)
    initial = read(request, widget)
    return unless initial

    initial.record.with_lock do
      current = read(request, widget)
      raise Toybaco::Security::WidgetHttpSession::RetryIntent unless current && current.record.id == initial.record.id

      current.record.update!(revoked_at: Time.current)
    end
  rescue ActiveRecord::RecordNotFound
    # An initially invalid cookie can be cleared. A change while waiting for
    # the lock must fail closed, without clearing an unknown newer identity.
    raise Toybaco::Security::WidgetHttpSession::RetryIntent if initial
  end

  def bootstrap(request, widget, intent:, legacy_token: nil)
    # Cached parents may still send this field. It grants no authority, even
    # when it is a correctly signed JWT. Only a cookie can resume a visitor.
    _legacy_token = legacy_token
    Toybaco::Security::WidgetSessionSecurityEpoch.with_creation_lock do
      bootstrap_session(request, widget, intent: intent)
    end
  end

  def bootstrap_session(request, widget, intent:, **options)
    link, binding, lock_scope = options.values_at(:link, :binding, :lock_scope)
    validate_bootstrap_request(request, intent)

    existing = bootstrap_cookie(request, widget)
    intent_digest = digest("bootstrap:#{widget.inbox.id}:#{intent}")
    grant = Toybaco::WidgetHandoff.find_by(code_digest: intent_digest, kind: 'bootstrap')
    require_known_bootstrap_target(grant, lock_scope) if grant
    return reconcile_bootstrap(grant, widget, intent, binding, request) if grant

    return bootstrap_existing(request, widget, link, intent, binding) if existing

    create_bootstrap(widget, link, intent_digest, intent, binding)
  rescue ActiveRecord::RecordNotUnique
    # The losing transaction, including a new anonymous ContactInbox, rolled back.
    grant = Toybaco::WidgetHandoff.find_by!(code_digest: intent_digest, kind: 'bootstrap')
    require_known_bootstrap_target(grant, lock_scope)
    reconcile_bootstrap(grant, widget, intent, binding, request)
  end

  private :bootstrap_session

  def validate_bootstrap_request(request, intent)
    raise ActiveRecord::RecordNotFound unless same_origin?(request) && intent.to_s.match?(/\A[a-f0-9]{64}\z/)
  end

  def bootstrap_cookie(request, widget)
    row = cookie_record(request, widget)
    return unless row
    return retire_bootstrap_cookie(request, widget, row) if row.retired?

    raise ActiveRecord::RecordNotFound unless row.current?

    new(row)
  rescue ActiveRecord::RecordNotFound
    raise Toybaco::Security::WidgetHttpSession::Conflict
  end

  def retire_bootstrap_cookie(request, widget, row)
    row.with_lock do
      current = cookie_record(request, widget)
      raise Toybaco::Security::WidgetHttpSession::RetryIntent unless current&.id == row.id && current.retired?

      current.update!(revoked_at: current.revoked_at || Time.current)
    end
    clear_cookie(request, widget)
    nil
  end

  private :clear_cookie, :retire_bootstrap_cookie

  def create_bootstrap(widget, link, bootstrap_digest, intent, binding)
    Toybaco::WidgetSessionRecord.transaction(requires_new: true) do
      link ||= widget.create_contact_inbox({})
      row = Toybaco::WidgetSessionRecord.create!(
        contact_inbox: link, inbox_id: widget.inbox.id,
        secret_digest: digest(SecureRandom.hex(32)), link_digest: link_digest(link), bootstrap_digest: bootstrap_digest,
        bootstrap_expires_at: Toybaco::Security::WidgetHttpSession::HANDOFF_TTL.from_now,
        rotated_at: Time.current, expires_at: expiry_days.days.from_now
      )
      secret = mac("bootstrap-cookie:#{row.id}:#{intent}")
      row.update!(secret_digest: digest(secret))
      record_bootstrap_intent(row, widget, intent, binding)
      [new(row), secret]
    end
  end
end
