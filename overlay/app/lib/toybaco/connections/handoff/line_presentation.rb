# frozen_string_literal: true

require_relative 'line_setup'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module Handoff
      module LinePresentation
        module_function

        def read(record)
          return {} unless record.provider == 'line' && %w[claimed completed].include?(record.state)

          inbox = record.account.inboxes.find_by(id: record.state == 'completed' ? record.result_inbox_id : record.inbox_id)
          id = inbox&.channel&.line_channel_id
          { line_available: LineSetup.available?, line_channel_id: id, webhook_url: id && webhook_url(id),
            settings_saved: record.state == 'completed', receipt_verified: false }
        end

        def webhook_url(id)
          origin = ENV.fetch('FRONTEND_URL').delete_suffix('/')
          raise Unavailable unless %w[https://app.toybaco.jp https://app.staging.toybaco.jp].include?(origin)
          raise Invalid unless id.to_s.match?(/\A\d{5,20}\z/)

          "#{origin}/webhooks/line/#{id}"
        end
      end
    end
  end
end
