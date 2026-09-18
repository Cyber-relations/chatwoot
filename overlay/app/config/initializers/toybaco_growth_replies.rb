# frozen_string_literal: true

require_relative '../../lib/toybaco/growth/reply_job_boundary'

Rails.application.config.to_prepare do
  SendReplyJob.prepend(Toybaco::Growth::ReplyJobBoundary::Send)
  Api::V1::Accounts::Conversations::MessagesController.prepend(Toybaco::Growth::ReplyJobBoundary::Retry)
end
