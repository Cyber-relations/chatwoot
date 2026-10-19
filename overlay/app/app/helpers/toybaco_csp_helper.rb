# frozen_string_literal: true

module ToybacoCspHelper
  # DashboardController obtains this platform-admin executable configuration from
  # InstallationConfig. No argument accepts customer, mail, or article HTML.
  def toybaco_dashboard_scripts_with_nonce
    fragment = Nokogiri::HTML::DocumentFragment.parse(@dashboard_scripts.to_s)
    fragment.css('script').each { |node| node['nonce'] = content_security_policy_nonce }
    fragment.to_html.html_safe # rubocop:disable Rails/OutputSafety
  end
end
