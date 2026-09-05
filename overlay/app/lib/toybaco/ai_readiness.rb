# frozen_string_literal: true

# Connection settings are not proof that the external worker can deliver a reply.
module Toybaco::AiReadiness
  module_function

  def for_account(account)
    assignments = AgentBotInbox.where(account_id: account.id, status: :active)
                               .joins(:inbox, :agent_bot)
                               .where(inboxes: { account_id: account.id })
    supported = assignments.where(agent_bots: { account_id: [nil, account.id] })
    configured = supported.where("NULLIF(TRIM(agent_bots.outgoing_url), '') IS NOT NULL").distinct.count(:inbox_id)
    conflicting = assignments.where.not(agent_bots: { account_id: [nil, account.id] }).exists?
    connection = configured.positive? ? 'configured' : 'unconnected'
    connection = 'unknown' if conflicting
    {
      'connection' => connection,
      'configured_inboxes' => configured,
      'total_inboxes' => account.inboxes.count,
      'live_verification' => 'unverified'
    }
  end
end
