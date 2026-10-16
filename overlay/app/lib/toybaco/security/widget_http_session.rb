# frozen_string_literal: true

# One identity/proof boundary shared by API, HTML bootstrap and ActionCable.
# Cookie secrets are never returned to JavaScript or stored in the database.
class Toybaco::Security::WidgetHttpSession
  class Conflict < StandardError; end
  class ExpiredProof < StandardError; end
  class RetryIntent < StandardError; end
  include Toybaco::Security::WidgetHttpProof
  extend Toybaco::Security::WidgetHttpBootstrap
  extend Toybaco::Security::WidgetHttpBootstrapIntents
  extend Toybaco::Security::WidgetHttpHandoffs

  PROOF_TTL = 24.hours
  HANDOFF_TTL = 60.seconds
  ROTATION_GRACE = 60.seconds
  attr_reader :record

  def self.digest(value)
    Digest::SHA256.hexdigest(value.to_s)
  end

  def self.link_digest(link)
    digest([link.inbox_id, link.source_id, link.pubsub_token].join(':'))
  end

  def self.key
    Rails.application.key_generator.generate_key('toybaco-widget-http-v1', 32)
  end

  def self.verifier
    Rails.application.message_verifier('toybaco-widget-recovery-v1')
  end

  def self.recovery(value, widget)
    return unless value.to_s.start_with?('tbwr1.')

    payload = verifier.verified(value.delete_prefix('tbwr1.'), purpose: 'widget-recovery')
    raise ActiveRecord::RecordNotFound unless payload.is_a?(Hash) && payload['inbox_id'] == widget.inbox.id

    row = Toybaco::WidgetSessionRecord.find_by!(id: payload['id'], inbox_id: widget.inbox.id)
    raise ActiveRecord::RecordNotFound unless row.current? && payload['link_digest'] == row.link_digest

    new(row)
  end

  def self.recovery_token(row, expires_at:)
    payload = { 'id' => row.id, 'inbox_id' => row.inbox_id, 'link_digest' => row.link_digest,
                'expires_at' => expires_at.to_i }
    "tbwr1.#{verifier.generate(payload, purpose: 'widget-recovery', expires_at: expires_at)}"
  end

  def self.socket(request, widget, proof)
    raise ActiveRecord::RecordNotFound unless request.headers['Origin'] == request.base_url

    return recovery_socket(request, widget, proof) if proof.to_s.start_with?('tbwr1.')

    cookie = read(request, widget)
    raise ActiveRecord::RecordNotFound unless cookie&.valid_proof?(proof)

    cookie
  end

  def self.recovery_socket(request, widget, proof)
    cookie = read_for_recovery(request, widget)
    session = recovery(proof, widget)
    raise ActiveRecord::RecordNotFound if cookie && cookie.record.contact_inbox_id != session.record.contact_inbox_id

    session
  end

  def self.mac(value)
    OpenSSL::HMAC.hexdigest('SHA256', key, value)
  end

  def self.cookie_name(widget, secure: true)
    raise ActiveRecord::RecordNotFound unless widget.website_token.match?(/\A[a-zA-Z0-9_-]+\z/)

    "#{secure ? '__Host-' : ''}tbw_#{widget.website_token}"
  end

  def self.read(request, widget)
    cookie = request.cookies[cookie_name(widget, secure: request.ssl?)]
    return if cookie.blank?

    parts = /\A([0-9]+)\.([a-f0-9]{64})\z/.match(cookie)
    raise ActiveRecord::RecordNotFound unless parts

    row = Toybaco::WidgetSessionRecord.find_by!(id: parts[1], inbox_id: widget.inbox.id)
    raise ActiveRecord::RecordNotFound unless matches_cookie?(row, parts[2]) && row.current?

    new(row)
  end

  def self.matches_cookie?(row, secret)
    supplied = digest(secret)
    return true if ActiveSupport::SecurityUtils.secure_compare(row.secret_digest, supplied)

    aliases = Toybaco::WidgetHandoff.where(
      widget_session_record_id: row.id, kind: 'bootstrap', cookie_digest: supplied, link_digest: row.link_digest
    )
    return true if aliases.exists?(['cookie_expires_at > ?', Time.current])
    return false unless row.previous_secret_digest.present? && row.rotated_at > ROTATION_GRACE.ago

    ActiveSupport::SecurityUtils.secure_compare(row.previous_secret_digest, supplied)
  end

  def self.read_for_recovery(request, widget)
    read(request, widget)
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def self.same_origin?(request)
    return false unless request.ssl? || development_host?(request.host)

    origin = request.headers['Origin']
    fetch_site = request.headers['Sec-Fetch-Site']
    return false if origin.present? && origin != request.base_url
    return false if fetch_site.present? && fetch_site != 'same-origin'

    # The custom header is not safelisted by CORS. With CORS closed, an image,
    # form or foreign document cannot manufacture it, including mutating GETs.
    request.headers['X-Toybaco-Widget'] == '1'
  end

  def self.development_host?(hostname)
    host = hostname.downcase.sub(/\.$/, '')
    %w[localhost ::1 [::1]].include?(host) || host.end_with?('.localhost', '.test') || host.match?(/\A127\.\d{1,3}\.\d{1,3}\.\d{1,3}\z/)
  end

  def self.legacy_link(widget, token)
    return if token.blank?

    claims = ::Widget::TokenService.new(token: token).decode_token
    raise ActiveRecord::RecordNotFound unless claims[:inbox_id] == widget.inbox.id

    link = widget.inbox.contact_inboxes.find_by!(source_id: claims[:source_id])
    raise ActiveRecord::RecordNotFound unless link.contact.account_id == widget.inbox.account_id

    link
  end

  def self.expiry_days
    value = InstallationConfig.find_by(name: 'WIDGET_TOKEN_EXPIRY')&.value
    days = (value.presence || ::Widget::TokenService::DEFAULT_EXPIRY_DAYS).to_i
    raise ActiveRecord::RecordNotFound unless days.positive?

    days
  end

  def initialize(record)
    @record = record
  end

  def claims
    link = record.contact_inbox
    { source_id: link.source_id, inbox_id: link.inbox_id }
  end

  def issue_cookie(request, widget, secret)
    return unless secret

    request.cookie_jar[self.class.cookie_name(widget, secure: request.ssl?)] = {
      value: "#{record.id}.#{secret}", path: '/', secure: request.ssl?, httponly: true,
      same_site: request.ssl? ? :none : :lax, partitioned: request.ssl?, expires: record.expires_at
    }
  end

  def mark_persisted!
    record.with_lock do
      raise ActiveRecord::RecordNotFound unless record.current?

      record.update!(persisted_at: record.persisted_at || Time.current)
    end
  end

  def rebind!(link)
    record.with_lock do
      same_scope = link.inbox_id == record.inbox_id && link.contact.account_id == link.inbox.account_id
      raise ActiveRecord::RecordNotFound unless record.current? && same_scope

      next_digest = self.class.link_digest(link)
      next if record.link_digest == next_digest

      secret = SecureRandom.hex(32)
      record.update!(contact_inbox: link, link_digest: next_digest, secret_digest: self.class.digest(secret),
                     previous_secret_digest: nil, rotated_at: Time.current)
      secret
    end
  end

  def revoke!(proof, widget)
    record.with_lock do
      authorized = if proof.to_s.start_with?('tbwr1.')
                     self.class.recovery(proof, widget).record.id == record.id
                   else
                     valid_proof?(proof)
                   end
      raise ActiveRecord::RecordNotFound unless authorized && record.current?

      link = record.contact_inbox
      Toybaco::Security::WidgetSession.revoke(link, source_id: link.source_id)
      record.update!(revoked_at: Time.current)
    end
  end

  def handoff(kind: 'popout')
    raise ActiveRecord::RecordNotFound unless record.current?

    code = SecureRandom.hex(32)
    Toybaco::WidgetHandoff.create!(
      widget_session_record: record, code_digest: self.class.digest(code), kind: kind,
      link_digest: record.link_digest, expires_at: HANDOFF_TTL.from_now
    )
    code
  end
end
