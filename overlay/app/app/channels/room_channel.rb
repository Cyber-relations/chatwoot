# frozen_string_literal: true

class RoomChannel < ApplicationCable::Channel
  periodically :verify_toybaco_session, every: 5.seconds
  def subscribed
    # TODO: should we only do ensure stream  if current account is present?
    # for now going ahead with guard clauses in update_subscription and broadcast_presence
    return reject unless current_user

    current_account
    ensure_stream
    update_subscription
    broadcast_presence
  rescue ActiveRecord::RecordNotFound
    reject
  end

  def update_presence
    return unless verify_toybaco_session

    update_subscription
    broadcast_presence
  end

  private

  def verify_toybaco_session
    return true unless @toybaco_session
    return true if @toybaco_session.current?

    stop_all_streams
    connection.close(reconnect: false)
    false
  rescue ActiveRecord::ActiveRecordError
    stop_all_streams
    connection.close(reconnect: false)
    false
  end

  def broadcast_presence
    return if @current_account.blank?

    data = { account_id: @current_account.id, users: ::OnlineStatusTracker.get_available_users(@current_account.id) }
    data[:contacts] = ::OnlineStatusTracker.get_available_contacts(@current_account.id) if @current_user.is_a? User
    ActionCable.server.broadcast(pubsub_token, { event: 'presence.update', data: data })
  end

  def ensure_stream
    if @current_user.is_a?(User)
      [pubsub_token, "account_#{@current_account.id}"].each do |stream|
        stream_from stream, coder: ActiveSupport::JSON do |message|
          transmit(message) if verify_toybaco_session
        end
      end
    else
      stream_from pubsub_token
    end
  end

  def update_subscription
    return if @current_account.blank?

    ::OnlineStatusTracker.update_presence(@current_account.id, @current_user.class.name, @current_user.id)
  end

  def pubsub_token
    @pubsub_token ||= params[:pubsub_token]
  end

  def current_user
    @current_user ||= if params[:user_id].blank?
                        ContactInbox.find_by!(pubsub_token: pubsub_token).contact
                      else
                        @toybaco_session = Toybaco::Security::CableSession.new(connection.request, params[:user_id], params[:account_id])
                        user = @toybaco_session.authenticate
                        user if user&.pubsub_token == pubsub_token
                      end
  end

  def current_account
    return if current_user.blank?

    @current_account ||= if @current_user.is_a? Contact
                           @current_user.account
                         else
                           @current_user.accounts.find(params[:account_id])
                         end
  end
end
