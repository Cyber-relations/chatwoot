# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/posting_execution_v3'

# No browser credentials grant admission at this signed service boundary.
class Toybaco::GrowthPostingExecutionsController < ApplicationController
  Protocol = Toybaco::Growth::PostingExecutionProtocol
  skip_before_action :set_current_user
  skip_around_action :switch_locale, :handle_with_exception
  rescue_from StandardError, with: :unavailable
  rescue_from Protocol::Invalid, JSON::ParserError, with: :forbidden

  def create
    response.headers['Cache-Control'] = 'no-store'
    raise Protocol::Invalid unless request.media_type == 'application/json'

    config = Protocol.configuration(ENV)
    raw = request.body.read(Protocol::MAX_BYTES + 1)
    payload = Protocol.request!(raw, header: request.headers[Protocol::HEADER], config: config, now: Time.now.utc)
    body = JSON.generate(Protocol.response(raw, execute(service(payload), payload)))
    signed_response(body, config)
  end

  private

  def signed_response(body, config)
    response.headers[Protocol::HEADER] = Protocol.signature(body, key: config.fetch(:key), now: Time.now.utc, direction: 'RESPONSE')
    render body: body, content_type: 'application/json'
  end

  def service(payload)
    client = Toybaco::Checkout::Client.new(ENV.fetch('TOYBACO_STRIPE_KEY', '')) if payload['operation'] == 'start'
    Toybaco::Growth::PostingExecutionV3.new(payload.fetch('execution'), client: client)
  end

  def execute(service, payload)
    case payload.fetch('operation')
    when 'start' then service.start!
    when 'status' then service.status
    when 'result' then service.result!(outcome: payload.fetch('outcome'), evidence_hash: payload.fetch('evidenceHash'))
    end
  end

  def forbidden(_error)
    head :forbidden
  end

  def unavailable(_error)
    head :service_unavailable
  end
end
