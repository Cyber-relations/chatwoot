# frozen_string_literal: true

# Run in the pinned Chatwoot image with bundle exec. Exercise the real Rails
# BaseController guard: a Toybaco subclass must still identify as the SES ingress.
require 'minitest/autorun'
require 'active_support/all'
require 'action_controller'
require 'action_mailbox'

mailbox_gem = Gem.loaded_specs.fetch('actionmailbox').full_gem_path
require File.join(mailbox_gem, 'app/controllers/action_mailbox/base_controller')
ses_gem = Gem.loaded_specs.fetch('aws-actionmailbox-ses').full_gem_path
require File.join(ses_gem, 'app/controllers/action_mailbox/ingresses/ses/inbound_emails_controller')
require_relative '../overlay/app/lib/toybaco/inbound_email'
require_relative '../overlay/app/app/controllers/toybaco/ses_inbound_emails_controller'

class ChatwootSesIngressIdentityTest < Minitest::Test
  def setup
    @previous_ingress = ActionMailbox.ingress
    @controller = Toybaco::SesInboundEmailsController.new
    @controller.response = ActionDispatch::Response.new
  end

  def teardown
    ActionMailbox.ingress = @previous_ingress
  end

  def test_ses_configuration_reaches_the_signature_validation_stage
    ActionMailbox.ingress = :ses
    @controller.send(:ensure_configured)

    assert_equal 200, @controller.response.status
    callbacks = @controller.class._process_action_callbacks.map(&:filter)
    assert_includes callbacks, :ensure_configured
    assert_includes callbacks, :verify_authenticity
    assert_includes callbacks, :validate_topic
  end

  def test_other_ingress_is_still_rejected
    ActionMailbox.ingress = :relay
    @controller.send(:ensure_configured)

    assert_equal 404, @controller.response.status
  end

  def test_unconfigured_ingress_is_still_rejected
    ActionMailbox.ingress = nil
    @controller.send(:ensure_configured)

    assert_equal 404, @controller.response.status
  end
end
