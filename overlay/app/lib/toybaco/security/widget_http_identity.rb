# frozen_string_literal: true

module Toybaco::Security::WidgetHttpIdentity
  private

  def identify_contact(contact)
    return super unless @toybaco_http_session

    @toybaco_http_session.record.with_lock do
      @toybaco_http_session.record.contact_inbox.with_lock do
        raise ActiveRecord::RecordNotFound unless @toybaco_http_session.record.current? && current_http_proof?

        previous_binding = @toybaco_http_session.record.link_digest
        super(contact)
        secret = @toybaco_http_session.rebind!(@contact_inbox)
        @toybaco_http_session.issue_cookie(request, @web_widget, secret)
        if @toybaco_http_authenticated
          @widget_http_identity_changed = previous_binding != @toybaco_http_session.record.link_digest
          @widget_auth_token = next_widget_proof
        end
      end
    end
  end

  def next_widget_proof
    return @toybaco_http_session.proof unless request.headers['X-Auth-Token'].to_s.start_with?('tbwr1.')

    old = Toybaco::Security::WidgetHttpSession.verifier.verified(
      request.headers['X-Auth-Token'].delete_prefix('tbwr1.'), purpose: 'widget-recovery'
    )
    raise ActiveRecord::RecordNotFound unless valid_recovery_reissue?(old)

    Toybaco::Security::WidgetHttpSession.recovery_token(
      @toybaco_http_session.record, expires_at: Time.zone.at(old.fetch('expires_at'))
    )
  end

  def valid_recovery_reissue?(claims)
    row = @toybaco_http_session.record
    claims.is_a?(Hash) && claims['id'] == row.id && claims['inbox_id'] == row.inbox_id &&
      claims['expires_at'].is_a?(Integer) && claims['expires_at'] > Time.current.to_i
  end
end
