# frozen_string_literal: true

# Run with the actual loaded application, never a replacement filter list.
require 'json'
require 'rack/mock'

filters = Rails.application.config.filter_parameters
marker = 'synthetic-widget-jwt-never-log'
request = ActionDispatch::Request.new(
  Rack::MockRequest.env_for("/widget?cw_conversation=#{marker}&locale=ja").merge(
    'action_dispatch.parameter_filter' => filters
  )
)
filtered = ActiveSupport::ParameterFilter.new(filters).filter(
  'cw_conversation' => marker, 'nested' => [{ 'cw_conversation' => marker }], 'locale' => 'ja'
)
http_fields = %w[legacy_token widget_proof handoff_code consume_intent]
http_parameters = http_fields.to_h { |name| [name, marker] }.merge('locale' => 'ja')
http_request = ActionDispatch::Request.new(
  Rack::MockRequest.env_for('/api/v1/widget/http_session', method: 'POST',
    'CONTENT_TYPE' => 'application/json', input: JSON.generate(http_parameters)).merge(
      'action_dispatch.parameter_filter' => filters
    )
)
http_filtered = http_request.filtered_parameters
checks = {
  flat_parameter_redacted: filtered['cw_conversation'] == '[FILTERED]',
  nested_parameter_redacted: filtered['nested'][0]['cw_conversation'] == '[FILTERED]',
  request_parameters_redacted: request.filtered_parameters['cw_conversation'] == '[FILTERED]',
  request_path_redacted: !request.filtered_path.include?(marker),
  unrelated_parameter_retained: filtered['locale'] == 'ja',
  widget_path_retained: request.filtered_path.start_with?('/widget?'),
  http_session_body_redacted: http_fields.all? { |name| http_filtered[name] == '[FILTERED]' },
  http_session_locale_retained: http_filtered['locale'] == 'ja'
}
abort 'widget parameter logging protection failed' unless checks.values.all?
puts JSON.generate(widget_parameter_logging: 'PASS', observations: checks.length,
                   URL_token_handoff_removed: false, HttpOnly_widget_cookie_accepted: false)
