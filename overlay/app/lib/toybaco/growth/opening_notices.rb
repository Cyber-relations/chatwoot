# frozen_string_literal: true

require 'timeout'
require_relative 'opening_access'

module Toybaco::Growth::OpeningNotices
  Access = Toybaco::Growth::OpeningAccess

  module_function

  def enabled?
    GlobalConfigService.load('TOYBACO_GROWTH_NOTICES_ENABLED', false) == true
  end

  # This runs inside the opening setup transaction; an uncertain attempt is never replaced.
  def initial!(request)
    return if Toybaco::OpeningNotice.exists?(opening_request_id: request.id)

    create!(request, 'initial', request.owner_id)
  end

  def retry!(request, actor_id:, request_id:, previous_id:, acknowledge_unknown: false)
    raise Access::Invalid unless enabled? && request_id.is_a?(String) && request_id.match?(uuid_pattern)

    request_id = request_id.dup
    Access.locked(request, actor_id: actor_id) do |_account, _owner|
      existing = Toybaco::OpeningNotice.find_by(opening_request_id: request.id, request_id: request_id)
      next existing if existing

      previous = Toybaco::OpeningNotice.where(opening_request_id: request.id).order(:id).last
      validate_retry!(previous, previous_id, acknowledge_unknown)
      recent = Toybaco::OpeningNotice.where(opening_request_id: request.id).where('created_at > ?', Time.now.utc - 1.day)
      raise Access::Invalid if recent.count >= 3

      create!(request, request_id, actor_id)
    end
  end

  def validate_retry!(previous, previous_id, acknowledge_unknown)
    raise Access::Invalid unless previous && previous.id == previous_id && %w[attempted uncertain cancelled].include?(previous.state)
    raise Access::Invalid if previous.created_at > Time.now.utc - 10.minutes
    raise Access::Invalid if previous.state == 'uncertain' && acknowledge_unknown != true
  end

  def create!(request, id, actor_id)
    Toybaco::OpeningNotice.create!(opening_request_id: request.id, request_id: id, actor_id: actor_id,
                                   retain_until: Time.now.utc + 10.years)
  end

  def uuid_pattern
    /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  end

  def sweep
    return unless enabled?

    Toybaco::OpeningNotice.where(state: 'queued').order(:id).limit(100).each do |notice|
      deliver!(notice)
    rescue StandardError => e
      Rails.logger.warn("TOYBACO_OPENING_NOTICE_PENDING id=#{notice.id} class=#{e.class}")
    end
  end

  def deliver!(notice)
    raise Access::Invalid if Account.connection.transaction_open?
    return unless enabled?

    claimed = notice.with_lock do
      next false unless notice.state == 'queued'

      notice.update!(state: 'dispatching', attempted_at: Time.now.utc)
      true
    end
    return unless claimed

    dispatch!(notice)
  end

  def dispatch!(notice)
    request = notice.opening_request
    # The intent was committed above. These current row locks cover SMTP and prevent
    # an owner/identity change before addressing the mail. A lost commit stays dispatching.
    Access.locked(request, actor_id: notice.actor_id) do |account, owner|
      notice.lock!('FOR UPDATE NOWAIT')
      raise Access::Invalid unless notice.state == 'dispatching' && enabled?

      Timeout.timeout(15) { send_mail!(account, owner) }
      notice.update!(state: 'attempted', finished_at: Time.now.utc)
    end
  rescue Access::Invalid
    finish!(notice, 'cancelled')
  rescue StandardError => e
    Rails.logger.warn("TOYBACO_OPENING_NOTICE_UNCERTAIN id=#{notice.id} class=#{e.class}")
    finish!(notice, 'uncertain')
  end

  def send_mail!(account, owner)
    delivery = Toybaco::OpeningMailer.with(account: account).guidance(owner)
    raise Access::Invalid unless delivery.message.perform_deliveries && delivery.message.raise_delivery_errors
    raise IOError unless delivery.deliver_now
  end

  def finish!(notice, state)
    notice.reload
    notice.with_lock do
      notice.update!(state: state, finished_at: Time.now.utc) if notice.state == 'dispatching'
    end
  end
end
