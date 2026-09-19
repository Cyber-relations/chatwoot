# frozen_string_literal: true

require_relative 'access'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module Handoff
      module Presentation
        module_function

        def owner(record, token: nil)
          value = { id: record.public_id, provider: record.provider, inbox_id: record.inbox_id,
                    state: state(record), expires_at: record.expires_at.utc.iso8601, result_inbox_id: record.result_inbox_id }
          value[:url] = "#{ENV.fetch('FRONTEND_URL').delete_suffix('/')}/toybaco/connections/help/#{record.public_id}##{token}" if token
          value
        end

        def recipient(record)
          { provider: record.provider, store_name: record.account.name.to_s.slice(0, 80), state: state(record),
            expires_at: record.expires_at.utc.iso8601, delivery_state: record.delivery_state,
            verification_remaining: [5 - record.verification_attempts, 0].max }
        end

        def state(record)
          return record.state if %w[completed revoked].include?(record.state)

          record.expires_at > Time.now.utc ? record.state : 'expired'
        end
      end
    end
  end
end
