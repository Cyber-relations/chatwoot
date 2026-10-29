# frozen_string_literal: true

require 'rails_helper'

# CASA 6.5.1: Action Cable は既定(application の logger)で、購読の stream 名(pubsub token)と購読解除の identifier を INFO に出す。
# web widget の訪問者は pubsub token だけで購読できる(room_channel.rb)ので、ログに残ると購読の資格になる。
# Action Cable 専用の logger(toybaco_log_redaction.rb)は WARN 以上だけを、token を伏せて application の logger へ書く。
# 残る ERROR の行は、生の frame・identifier・例外の文を出さず、class と command・channel・action の名前だけを出す(CableSafeLog)。
RSpec.describe Toybaco::Security::CableLog do
  let(:account) { create(:account) }
  let(:contact_inbox) do
    widget = Channel::WebWidget.create!(account: account, website_url: 'https://customer.example.test')
    inbox = Inbox.create!(account: account, channel: widget, name: 'Synthetic cable log')
    create(:contact_inbox, inbox: inbox, contact: create(:contact, account: account))
  end

  # application の logger に production と同じ info の出力先を足して、その間に書かれた行を返す。
  def capture_application_log
    io = StringIO.new
    sink = ActiveSupport::Logger.new(io).tap { |logger| logger.level = :info }
    Rails.logger.broadcast_to(sink)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(sink)
  end

  def message_type(transmitted)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    while (left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)).positive?
      message = transmitted.pop(timeout: left)
      return message[:type] if message&.key?(:type)
    end
  end

  # stream の購読の完了(確認の送信と「streaming from」の行)は event loop の中で起きる。後ろに積んだ処理が終わるまで待つ。
  def drain_event_loop
    done = Queue.new
    ActionCable.server.event_loop.post { done << true }
    done.pop(timeout: 5)
  end

  it 'identifier の JSON・inspect の中の JSON・Hash の表示・stream 名・HTTP widget の proof の値を伏せ、ほかは変えない' do
    token = SecureRandom.base58(24)
    proof = "tbwhttp1.#{SecureRandom.hex(12)}.#{SecureRandom.urlsafe_base64(32)}"
    lines = [%({"channel":"RoomChannel","pubsub_token":"#{token}","account_id":1}),
             { 'identifier' => { channel: 'RoomChannel', pubsub_token: token }.to_json }.inspect,
             { 'pubsub_token' => token }.inspect, { pubsub_token: token }.inspect,
             "RoomChannel is streaming from #{token}", "[ActionCable] Broadcasting to #{token}: {}",
             %({"channel":"RoomChannel","pubsub_token":"#{proof}"}), "widget proof #{proof} rejected"]
    masked = lines.map { |line| described_class.mask(line) }
    expect(masked.select { |line| [token, proof, proof.split('.').last].any? { |secret| line.include?(secret) } }).to eq([])
    expect(masked).to all(include('[FILTERED]'))
    expect(described_class.mask('RoomChannel#update_presence account_id=1')).to eq('RoomChannel#update_presence account_id=1')
  end

  def stubbed_connection
    env = Rack::MockRequest.env_for('https://app.example.test/cable', 'HTTP_ORIGIN' => 'https://app.example.test')
    ApplicationCable::Connection.new(ActionCable.server, env).tap do |connection|
      transmitted = Queue.new
      connection.define_singleton_method(:transmitted) { transmitted }
      connection.define_singleton_method(:transmit) { |message| transmitted << message }
      connection.define_singleton_method(:close) { |**_options| nil }
    end
  end

  it '切断後に届いた frame の ERROR 行は frame を出さず大きさだけを出す(key・値を Unicode の escape で書いた identifier でも)' do
    token = contact_inbox.pubsub_token
    escaped = token.chars.map { |char| format('\\u%04x', char.ord) }.join
    identifiers = [{ channel: 'RoomChannel', pubsub_token: token }.to_json,
                   %({"channel":"RoomChannel","\\u0070ubsub_token":"#{token}"}),
                   %({"channel":"RoomChannel","pubsub_token":"#{escaped}"})]
    frames = identifiers.map { |identifier| { command: 'subscribe', identifier: identifier }.to_json }
    env = Rack::MockRequest.env_for('https://app.example.test/cable', 'HTTP_ORIGIN' => 'https://app.example.test')
    connection = ApplicationCable::Connection.new(ActionCable.server, env)
    # WebSocket の無い Connection は alive? が偽なので、Connection::Base#dispatch_websocket_message の切断後の分岐を通る。
    log = capture_application_log { frames.each { |frame| connection.dispatch_websocket_message(frame) } }
    expect(frames.first.inspect).to include('\\\\\\"pubsub_token\\\\\\"')
    expect(log.scan('Ignoring message processed after the WebSocket was closed').size).to eq(3)
    expect(log).to include("(#{frames.first.bytesize} bytes)")
    expect([token, escaped[6..], 'pubsub_token', 'u0070ubsub', 'identifier'].select { |fragment| log.include?(fragment) }).to eq([])
  end

  it '実 Connection で widget の購読・不正な command・購読解除を通しても、ログに pubsub token と INFO の stream の行を出さない' do
    token = contact_inbox.pubsub_token
    identifier = { channel: 'RoomChannel', pubsub_token: token }.to_json
    env = Rack::MockRequest.env_for('https://app.example.test/cable', 'HTTP_ORIGIN' => 'https://app.example.test')
    connection = ApplicationCable::Connection.new(ActionCable.server, env)
    transmitted = Queue.new
    connection.define_singleton_method(:transmit) { |message| transmitted << message }
    connection.define_singleton_method(:close) { |**_options| nil }
    confirmation = nil
    log = capture_application_log do
      connection.handle_channel_command('command' => 'subscribe', 'identifier' => identifier)
      confirmation = message_type(transmitted)
      drain_event_loop
      connection.handle_channel_command('command' => 'fixture-unknown', 'identifier' => identifier)
    ensure
      connection.handle_channel_command('command' => 'unsubscribe', 'identifier' => identifier)
    end
    expect(confirmation).to eq('confirm_subscription')
    expect(log).to include('Received unrecognized command (command=[unknown] channel=RoomChannel)')
    expect([token, 'streaming from', 'Unsubscribing from channel', 'Broadcasting to'].select { |fragment| log.include?(fragment) }).to eq([])
  end

  it '失敗した command・処理できない action・worker の例外の行は、class と command・channel・action の名前だけを出す' do
    token = contact_inbox.pubsub_token
    note = "ログ確認のメモ #{SecureRandom.hex(4)}"
    secret = "fs#{SecureRandom.hex(4)}"
    identifier = { channel: 'RoomChannel', pubsub_token: token }.to_json
    # 購読していない identifier の解除は、上流では identifier を含む例外の文(Unable to find subscription with identifier: …)と
    # data の inspect を ERROR に出す。
    unknown = { channel: 'RoomChannel', pubsub_token: "#{token}x" }.to_json
    malformed = %({"command":"message" #{secret}})
    # 上流の Server::Worker#invoke は、この解析の失敗の文(frame の断片を含む)を ERROR に出す。
    expect { ActiveSupport::JSON.decode(malformed) }.to raise_error(JSON::ParserError, /#{secret}/)
    connection = stubbed_connection
    confirmation = nil
    log = capture_application_log do
      connection.handle_channel_command('command' => 'unsubscribe', 'identifier' => unknown)
      connection.handle_channel_command('command' => 'subscribe', 'identifier' => identifier)
      confirmation = message_type(connection.transmitted)
      drain_event_loop
      connection.handle_channel_command('command' => 'message', 'identifier' => identifier,
                                        'data' => { action: 'fixture_action', note: note }.to_json)
      connection.send(:websocket).define_singleton_method(:alive?) { true }
      ActionCable.server.worker_pool.invoke(connection, :dispatch_websocket_message, malformed, connection: connection)
    ensure
      connection.handle_channel_command('command' => 'unsubscribe', 'identifier' => identifier)
    end
    expect(confirmation).to eq('confirm_subscription')
    expect(log).to include('Could not execute command (command=unsubscribe channel=RoomChannel) [RuntimeError]',
                           'Unable to process RoomChannel#fixture_action', 'There was an exception - JSON::ParserError')
    expect([token, note, secret, 'pubsub_token', 'Unable to find subscription'].select { |fragment| log.include?(fragment) }).to eq([])
  end

  it 'alive? が true の直後に切断しても再判定で生 frame の ERROR 行へ戻らない' do
    connection = stubbed_connection
    token = SecureRandom.base58(24)
    note = "frame-body-#{SecureRandom.hex(8)}"
    payload = { 'command' => 'fixture_unknown', 'identifier' => { channel: 'RoomChannel', pubsub_token: token }.to_json, 'note' => note }
    websocket = connection.send(:websocket)
    allow(websocket).to receive(:alive?).and_return(true, false)
    allow(connection).to receive(:handle_channel_command).and_call_original

    log = capture_application_log { connection.dispatch_websocket_message(payload.to_json) }

    expect(websocket).to have_received(:alive?).once
    expect(connection).to have_received(:handle_channel_command).with(payload).once
    expect(log).to include('Received unrecognized command (command=fixture_unknown channel=RoomChannel)')
    expect([token, note, 'Ignoring message processed after'].select { |fragment| log.include?(fragment) }).to eq([])
  end

  it '有効な JSON frame の identifier の Unicode 引用符を、inspect の深さによらず伏せる' do
    token = SecureRandom.base58(24)
    identifier = { channel: 'RoomChannel', pubsub_token: token, account_id: 7 }.to_json
    frame = { command: 'subscribe', identifier: identifier }.to_json.gsub('\\"') { '\u0022' }
    expect(JSON.parse(frame).fetch('identifier')).to eq(identifier)

    [frame, frame.inspect, frame.inspect.inspect].each do |form|
      masked = described_class.mask(form)
      expect(masked).not_to include(token)
      expect(masked).to include('[FILTERED]', 'account_id', ':7')
      # CableLog の網だけでなく、実際の WARN 出力からも消える。
      log = capture_application_log { ActionCable.server.config.logger.warn(form) }
      expect(log).not_to include(token)
      expect(log).to include('[FILTERED]', 'account_id', ':7')
    end
  end
end
