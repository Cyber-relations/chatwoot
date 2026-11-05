# frozen_string_literal: true

require 'uri'

# Run before Rails parameter parsing (including malformed JSON and multipart).
# ENV/ActionMailbox.ingress changes cannot enable an unsupported provider route.
class Toybaco::InboundEmail::IngressBoundary
  def initialize(app)
    @app = app
  end

  def call(env)
    path = URI::DEFAULT_PARSER.unescape(env['PATH_INFO'].to_s).squeeze('/').chomp('/')
    if action_mailbox_path?(path) && path != Toybaco::InboundEmail::INGRESS_PATH
      return [404, { 'content-type' => 'text/plain', 'content-length' => '0' }, []]
    end

    @app.call(env)
  end

  private

  def action_mailbox_path?(path)
    path == Toybaco::InboundEmail::INGRESS_SCOPE || path.start_with?("#{Toybaco::InboundEmail::INGRESS_SCOPE}/")
  end
end
