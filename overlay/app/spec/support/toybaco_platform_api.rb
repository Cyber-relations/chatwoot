# frozen_string_literal: true

# Upstream's Platform API specs exercise the explicitly enabled API contract.
# The default-off contract is tested separately by platform_api_guard_spec.rb.
RSpec.configure do |config|
  config.around(:each, file_path: %r{/spec/controllers/platform/}) do |example|
    with_modified_env(TOYBACO_PLATFORM_API_ENABLED: 'true') { example.run }
  end
end
