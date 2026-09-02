# frozen_string_literal: true

expected_revision = ENV.fetch('TOYBACO_EXPECTED_CHATWOOT_REVISION')
actual_revision = Rails.root.join('.git_sha').read.strip
abort "Chatwoot source revision mismatch: #{actual_revision}" unless actual_revision == expected_revision

middleware_present = Rails.application.middleware.middlewares.any? do |entry|
  entry.klass == Toybaco::DashboardFramePolicy
end
abort 'Toybaco::DashboardFramePolicy is not installed' unless middleware_present
brand_injector_present = Rails.application.middleware.middlewares.any? do |entry|
  entry.klass == Toybaco::BrandInjector
end
abort 'Toybaco::BrandInjector is not installed' unless brand_injector_present
Toybaco::PostizOrigin.fetch!

oidc_paths = Rails.application.routes.routes.map { |route| route.path.spec.to_s }
%w[
  /toybaco/connect(.:format)
  /toybaco/oidc/authorize(.:format)
  /toybaco/oidc/token(.:format)
  /toybaco/oidc/userinfo(.:format)
].each do |path|
  abort "OIDC route is not reachable: #{path}" unless oidc_paths.include?(path)
end

if Toybaco::InboundEmail.ingress_enabled?
  ingress = "#{Toybaco::InboundEmail::INGRESS_PATH}(.:format)"
  abort "SES ActionMailbox ingress is not reachable: #{ingress}" unless oidc_paths.include?(ingress)
  ingress_routes = Rails.application.routes.routes.select do |route|
    route.path.spec.to_s == ingress
  end
  verbs = ingress_routes.map { |route| route.verb.to_s }.join(' ')
  abort "SES ActionMailbox ingress is not POST: #{verbs}" unless verbs.include?('POST')
  abort "SES ActionMailbox GET ingress is missing: #{verbs}" unless verbs.include?('GET')
else
  abort 'SES ActionMailbox ingress env is required for production smoke'
end

abort 'AccountUser lifecycle hook is not installed' unless
  AccountUser < Toybaco::PostizLifecycle::AccountUserHooks
abort 'Account lifecycle hook is not installed' unless
  Account < Toybaco::PostizLifecycle::AccountHooks
abort 'User lifecycle hook is not installed' unless
  User < Toybaco::PostizLifecycle::UserHooks
abort 'Postiz DB boundary is not configured' unless Toybaco::PostizSync.configured?
abort 'FORCE_SSL must be true in production' unless ENV['FORCE_SSL'] == 'true'
abort 'Account locale default must be Japanese' unless Account.columns_hash.fetch('locale').default.to_i == 7

puts 'TOYBACO_CHATWOOT_PRODUCTION_SMOKE=PASS post-entry=automatic locale-default=ja ses-ingress=drawn'
