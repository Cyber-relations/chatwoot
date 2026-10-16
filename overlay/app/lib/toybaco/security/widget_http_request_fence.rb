# frozen_string_literal: true

module Toybaco::Security::WidgetHttpRequestFence
  IDENTITY_ACTIONS = {
    'Api::V1::Widget::ContactsController' => %w[set_user update],
    'Api::V1::Widget::ConversationsController' => %w[create],
    'Api::V1::Widget::MessagesController' => %w[create update]
  }.freeze

  private

  def with_toybaco_http_session_fence(&)
    return yield unless @toybaco_http_session

    Toybaco::Security::WidgetContactLock.synchronize(@web_widget.inbox.account_id, exclusive: widget_identity_write?) do
      with_locked_widget_identity(&)
    end
  end

  def widget_identity_write?
    IDENTITY_ACTIONS.fetch(self.class.name, []).include?(action_name)
  end

  def with_locked_widget_identity
    @toybaco_http_session.record.with_lock do
      row = @toybaco_http_session.record
      link = row.contact_inbox.reload
      link.with_lock do
        raise ActiveRecord::RecordNotFound unless row.current? && same_request_identity?(link) && current_http_proof?

        @contact_inbox = link
        @contact = link.contact if instance_variable_defined?(:@contact)
        yield
      end
    end
  end

  def same_request_identity?(link)
    @contact_inbox&.id == link.id && @auth_token_params[:source_id] == link.source_id
  end

  def current_http_proof?
    token = request.headers['X-Auth-Token'].to_s
    if token.start_with?('tbwr1.')
      Toybaco::Security::WidgetHttpSession.recovery(token, @web_widget).record.id == @toybaco_http_session.record.id
    elsif token.start_with?('tbwp1.')
      @toybaco_http_session.valid_proof?(token)
    else
      claims = ::Widget::TokenService.new(token: token).decode_token
      expected = @toybaco_http_session.claims
      claims[:inbox_id] == expected[:inbox_id] && claims[:source_id] == expected[:source_id]
    end
  end
end
