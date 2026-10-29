# frozen_string_literal: true

# Action Cable のログに、生の frame・購読の identifier(web widget の pubsub token を含む)・例外の文を出さない(CASA 6.5.1)。
# 出すのは class と安全な属性(command・channel の class 名・action 名)だけ。上流(actioncable 7.2.3.2)の次の行を置き換える。
# - Connection::Base#dispatch_websocket_message(base.rb 105 行): 切断後に届いた frame を inspect して ERROR に出す。
# - Connection::Subscriptions#execute_command(subscriptions.rb 26・30 行): 認識できない command と、失敗した command の
#   data(identifier を含む)を inspect し、例外の文(Unable to find subscription with identifier: … など)も出す。
# - Connection::Subscriptions#add・#remove(46・51 行): channel の値と identifier をそのまま出す。
# - Channel::Base#action_signature(299-308 行): action の引数を inspect する(Unable to process … の ERROR と DEBUG)。
# - Server::Worker#invoke(worker.rb 58-66 行): frame の JSON の解析の失敗など、例外の文(frame の断片を含む)を ERROR に出す。
# 動き(購読・解除・action の実行・切断・例外の後の handle_exception)は上流のまま。上流の版を上げるときは、写した本体を照らし合わせる。
module Toybaco::Security::CableSafeLog
  UNKNOWN = '[unknown]'
  # channel の class 名(RoomChannel・Foo::BarChannel)、command・action の名前の形。外れた値は出さない。
  SAFE_NAME = /\A[A-Za-z_][A-Za-z0-9_]{0,63}(?:::[A-Za-z_][A-Za-z0-9_]{0,63}){0,4}\z/

  def self.safe_name(value)
    text = value.to_s
    SAFE_NAME.match?(text) ? text : UNKNOWN
  end

  # identifier(JSON の文字列)から channel の class 名だけを取り出す。読めなければ [unknown]。
  def self.channel_of(identifier)
    decoded = ActiveSupport::JSON.decode(identifier.to_s)
    safe_name(decoded.is_a?(Hash) ? decoded['channel'] : nil)
  rescue StandardError
    UNKNOWN
  end

  def self.summary(data)
    data = {} unless data.is_a?(Hash)
    "command=#{safe_name(data['command'])} channel=#{channel_of(data['identifier'])}"
  end

  def self.backtrace(error)
    Array(error.backtrace).first(5).join(' | ')
  end

  # ActionCable::Connection::Base に prepend する。
  module Connection
    def dispatch_websocket_message(websocket_message)
      # super は alive? をもう一度調べ、途中で切断すると生の frame を出す。上流の配送本体をここで一度だけ分岐する。
      if websocket.alive?
        handle_channel_command decode(websocket_message)
      else
        logger.error "Ignoring message processed after the WebSocket was closed (#{websocket_message.to_s.bytesize} bytes)"
      end
    end
  end

  # ActionCable::Connection::Subscriptions に prepend する。
  module Subscriptions
    def execute_command(data)
      case data['command']
      when 'subscribe'   then add data
      when 'unsubscribe' then remove data
      when 'message'     then perform_action data
      else
        logger.error "Received unrecognized command (#{Toybaco::Security::CableSafeLog.summary(data)})"
      end
    rescue Exception => e # rubocop:disable Lint/RescueException
      @connection.rescue_with_handler(e)
      logger.error "Could not execute command (#{Toybaco::Security::CableSafeLog.summary(data)}) [#{e.class}]: " \
                   "#{Toybaco::Security::CableSafeLog.backtrace(e)}"
    end

    def add(data)
      id_key = data['identifier']
      id_options = ActiveSupport::JSON.decode(id_key).with_indifferent_access

      return if subscriptions.key?(id_key)

      subscription_klass = id_options[:channel].safe_constantize

      if subscription_klass && subscription_klass < ActionCable::Channel::Base
        subscription = subscription_klass.new(connection, id_key, id_options)
        subscriptions[id_key] = subscription
        subscription.subscribe_to_channel
      else
        logger.error "Subscription class not found: #{Toybaco::Security::CableSafeLog.safe_name(id_options[:channel])}"
      end
    end

    def remove(data)
      logger.info "Unsubscribing from channel: #{Toybaco::Security::CableSafeLog.channel_of(data['identifier'])}"
      remove_subscription find(data)
    end
  end

  # ActionCable::Channel::Base に prepend する。DEBUG の行と Unable to process … の ERROR は「Channel#action」だけになる。
  module Channel
    private

    def action_signature(action, _data)
      "#{self.class.name}##{Toybaco::Security::CableSafeLog.safe_name(action)}"
    end
  end

  # ActionCable::Server::Worker に prepend する。例外は class と backtrace だけを出す。
  module Worker
    def invoke(receiver, method, *, connection:, &)
      work(connection) do
        receiver.send(method, *, &)
      rescue Exception => e # rubocop:disable Lint/RescueException
        logger.error "There was an exception - #{e.class}"
        logger.error Array(e.backtrace).join("\n")

        receiver.handle_exception if receiver.respond_to?(:handle_exception)
      end
    end
  end
end
