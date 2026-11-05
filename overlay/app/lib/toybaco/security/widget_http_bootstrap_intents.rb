# frozen_string_literal: true

module Toybaco::Security::WidgetHttpBootstrapIntents
  def bootstrap_existing(request, widget, link, intent, binding)
    existing = bootstrap_cookie(request, widget)
    raise Toybaco::Security::WidgetHttpSession::Conflict unless existing

    Toybaco::WidgetSessionRecord.transaction(requires_new: true) do
      existing.record.with_lock do
        current = bootstrap_cookie(request, widget)
        raise Toybaco::Security::WidgetHttpSession::Conflict unless current && current.record.id == existing.record.id

        current.record.contact_inbox.with_lock do
          raise ActiveRecord::RecordNotFound unless current.record.current?
          raise Toybaco::Security::WidgetHttpSession::Conflict if link && link.id != current.record.contact_inbox_id

          record_bootstrap_intent(current.record, widget, intent, binding)
          [current, nil]
        end
      end
    end
  end

  def require_known_bootstrap_target(grant, scope)
    return unless scope&.exclude?(grant.widget_session_record_id)

    raise Toybaco::Security::WidgetHttpSession::RetryIntent
  end

  def bootstrap_input_digest(row, binding)
    mode = binding.nil? ? 'cookie' : 'handoff'
    digest([mode, row.inbox_id, row.contact_inbox_id, binding.nil? ? '' : digest(binding)].join(':'))
  end

  def record_bootstrap_intent(row, widget, intent, binding)
    # The 60s intent may reconcile a lost response, including an existing
    # cookie session. Its alternate cookie secret is hashed, never plaintext.
    # Cookie authorization remains bounded by the original session deadline;
    # it does not depend on keeping an intent replayable beyond 60 seconds.
    Toybaco::WidgetHandoff.create!(
      widget_session_record: row, kind: 'bootstrap', code_digest: digest("bootstrap:#{widget.inbox.id}:#{intent}"),
      consume_intent_digest: bootstrap_input_digest(row, binding), link_digest: row.link_digest,
      expires_at: Toybaco::Security::WidgetHttpSession::HANDOFF_TTL.from_now,
      cookie_digest: digest(mac("bootstrap-cookie:#{row.id}:#{intent}")), cookie_expires_at: row.expires_at
    )
  end

  def reconcile_bootstrap(grant, widget, intent, binding, request)
    with_current_grant_session(grant, widget) do |row|
      raise ActiveRecord::RecordNotFound unless grant.consume_intent_digest == bootstrap_input_digest(row, binding)

      cookie = bootstrap_cookie(request, widget)
      raise Toybaco::Security::WidgetHttpSession::Conflict if cookie && cookie.record.id != row.id

      [new(row), cookie ? nil : mac("bootstrap-cookie:#{row.id}:#{intent}")]
    end
  end
end
