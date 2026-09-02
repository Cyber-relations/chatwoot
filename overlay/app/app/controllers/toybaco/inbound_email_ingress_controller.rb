# frozen_string_literal: true

# SNS 本文なしの GET を Chatwoot HTML 404 に落とさない。
# POST は aws-actionmailbox-ses の Ingresses::Ses::InboundEmails#create。
class Toybaco::InboundEmailIngressController < ActionController::Base # rubocop:disable Rails/ApplicationController
  skip_forgery_protection

  def method_not_allowed
    head :method_not_allowed
  end
end
