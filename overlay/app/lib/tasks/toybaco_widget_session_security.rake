# frozen_string_literal: true

namespace :toybaco do
  desc 'Retire widget sessions before now; run after old tasks drain (no arguments)'
  task widget_session_security_cutover: :environment do |_task, args|
    raise ArgumentError, 'Widget session security cutover takes no arguments' unless args.extras.empty?

    cutover, advanced = Toybaco::Security::WidgetSessionSecurityEpoch.advance!
    puts "TOYBACO_WIDGET_SESSION_SECURITY_CUTOVER=#{cutover.iso8601(6)}"
    puts advanced ? 'Widget session security cutover advanced.' : 'Widget session security cutover stayed.'
  end
end
