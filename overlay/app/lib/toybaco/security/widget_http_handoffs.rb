# frozen_string_literal: true

module Toybaco::Security::WidgetHttpHandoffs
  def consume(request, widget, code:, intent:)
    validate_handoff_request(request, code, intent)
    Toybaco::WidgetHandoff.transaction do
      grant = Toybaco::WidgetHandoff.find_by!(code_digest: digest(code), kind: 'popout')
      scope = lock_consume_sessions(request, widget, grant, intent)
      with_current_grant_session(grant, widget) do |parent|
        next reconcile_handoff(request, widget, grant, intent) if grant.consumed_at

        session, secret = bootstrap_from_parent(request, widget, parent, intent, scope)
        verify_child_identity(session.record, parent)
        grant.update!(consumed_at: Time.current, consumed_session_id: session.record.id, consume_intent_digest: digest(intent))
        [session, secret]
      end
    end
  end

  def verify_child_identity(child, parent)
    same_contact = child.contact_inbox_id == parent.contact_inbox_id && child.inbox_id == parent.inbox_id
    raise ActiveRecord::RecordNotFound unless same_contact
  end

  def consume_session_ids(request, widget, grant, intent)
    cookie = bootstrap_cookie(request, widget)
    existing_intent = Toybaco::WidgetHandoff.find_by(code_digest: digest("bootstrap:#{widget.inbox.id}:#{intent}"), kind: 'bootstrap')
    [grant.widget_session_record_id, grant.consumed_session_id, cookie&.record&.id, existing_intent&.widget_session_record_id].compact.uniq.sort
  end

  def lock_consume_sessions(request, widget, grant, intent)
    ids = consume_session_ids(request, widget, grant, intent)
    rows = Toybaco::WidgetSessionRecord.where(id: ids).order(:id).lock.to_a
    raise ActiveRecord::RecordNotFound unless rows.size == ids.size

    grant.reload
    current_ids = [grant.widget_session_record_id, grant.consumed_session_id].compact
    raise Toybaco::Security::WidgetHttpSession::RetryIntent unless (current_ids - ids).empty?

    lock_consume_contacts(rows)
    ids
  end

  def lock_consume_contacts(rows)
    ids = rows.map(&:contact_inbox_id).uniq.sort
    raise ActiveRecord::RecordNotFound unless ContactInbox.where(id: ids).order(:id).lock.to_a.size == ids.size
  end

  def validate_handoff_request(request, code, intent)
    valid_codes = [code, intent].all? { |value| value.to_s.match?(/\A[a-f0-9]{64}\z/) }
    raise ActiveRecord::RecordNotFound unless same_origin?(request) && valid_codes
  end

  def with_current_grant_session(grant, widget)
    # The grant association may have been read before an identity change.
    # Read and lock the actual parent row until child creation/consume finishes.
    parent = Toybaco::WidgetSessionRecord.find(grant.widget_session_record_id)
    parent.with_lock do
      parent.contact_inbox.with_lock do
        grant.with_lock do
          same_scope = parent.inbox_id == widget.inbox.id && parent.link_digest == grant.link_digest
          raise ActiveRecord::RecordNotFound unless grant.expires_at > Time.current && parent.current? && same_scope

          yield parent
        end
      end
    end
  end

  def bootstrap_from_parent(request, widget, parent, intent, scope)
    link = parent.contact_inbox
    legacy = ::Widget::TokenService.new(payload: { source_id: link.source_id, inbox_id: link.inbox_id }).generate_token
    bootstrap(request, widget, legacy_token: legacy, intent: intent, lock_scope: scope)
  end

  def reconcile_handoff(request, widget, grant, intent)
    row = handoff_replay_row(grant, widget, intent)
    return [new(row), nil] if matching_replay_cookie?(request, widget, row)

    recorded = Toybaco::WidgetHandoff.exists?(
      widget_session_record_id: row.id, kind: 'bootstrap',
      code_digest: digest("bootstrap:#{widget.inbox.id}:#{intent}"), link_digest: row.link_digest
    )
    raise ActiveRecord::RecordNotFound unless recorded

    [new(row), mac("bootstrap-cookie:#{row.id}:#{intent}")]
  end

  def handoff_replay_row(grant, widget, intent)
    raise ActiveRecord::RecordNotFound unless grant.consume_intent_digest == digest(intent)

    row = Toybaco::WidgetSessionRecord.find(grant.consumed_session_id)
    raise ActiveRecord::RecordNotFound unless row.current? && row.inbox_id == widget.inbox.id && row.link_digest == grant.link_digest

    row
  end

  def matching_replay_cookie?(request, widget, row)
    cookie = read(request, widget)
    return false unless cookie

    raise Toybaco::Security::WidgetHttpSession::Conflict unless cookie.record.id == row.id

    true
  end

  def recover(request, widget, code:, intent:)
    validate_handoff_request(request, code, intent)
    Toybaco::WidgetHandoff.transaction do
      grant = Toybaco::WidgetHandoff.find_by!(code_digest: digest(code), kind: 'recovery')
      with_current_grant_session(grant, widget) do |row|
        raise ActiveRecord::RecordNotFound if grant.consumed_at && grant.consume_intent_digest != digest(intent)

        grant.update!(consumed_at: grant.consumed_at || Time.current, consume_intent_digest: digest(intent))
        [new(row), recovery_token(row, expires_at: grant.created_at + 2.hours)]
      end
    end
  end
end
