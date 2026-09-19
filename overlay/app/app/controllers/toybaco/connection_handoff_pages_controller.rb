# frozen_string_literal: true

require_relative 'connection_handoff_requests_controller'
require_relative '../../../lib/toybaco/connections/handoff/line_setup'
require_relative '../../../lib/toybaco/connections/handoff/mail_gateway'

class Toybaco::ConnectionHandoffPagesController < Toybaco::ConnectionHandoffRequestsController
  LABELS = { 'line' => 'LINE公式', 'gmail' => 'Google', 'microsoft' => 'Microsoft' }.freeze

  def show
    bind_provider

    response.headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; " \
                                                  "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
    render template: 'toybaco/connections/handoff_owner', layout: false
  end

  private

  def bind_provider
    record = selected if params[:id].present?
    @provider = chosen_provider(record)
    @provider_label = LABELS.fetch(@provider) { raise Handoff::Invalid }
    @inbox_id = record ? record.inbox_id : requested_inbox
    Handoff::Access.target!(@account, @provider, @inbox_id)
    @create_available = Handoff::Access.enabled? && provider_available?
    raise Handoff::Unavailable unless @create_available || record
  end

  def chosen_provider(record)
    return record.provider if record

    params[:provider].presence || 'line'
  end

  def requested_inbox
    return if params[:inbox_id].blank?
    raise Handoff::Invalid unless params[:inbox_id].to_s.match?(/\A[1-9]\d{0,15}\z/)

    params[:inbox_id].to_i
  end

  def provider_available?
    return Handoff::LineSetup.available? if @provider == 'line'

    Handoff::MailGateway.new(@provider).allowed?(@account)
  end
end
