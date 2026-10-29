# frozen_string_literal: true

require 'rails_helper'

# CASA 6.5.1: application の logger の全行に、出す直前の最後の網(LogScrub)を入れる。経路ごとの上書き(filter_parameters・
# JobErrorLog・CableSafeLog など)の取りこぼしを拾う。伏せるのはメールアドレス・pubsub_token の値・widget の token・JWT・
# 封印した暗号文の形。式は読み込み時に一度だけ作り、どれも線形時間で照合する。
RSpec.describe Toybaco::Security::LogScrub do
  let(:token) { "Tok#{SecureRandom.alphanumeric(21)}" }

  def unicode_escape(text)
    text.chars.map { |char| format('\\u%04x', char.ord) }.join
  end

  def base64url(text)
    Base64.urlsafe_encode64(text, padding: false)
  end

  it '切断後の frame の行の pubsub_token の値を、key・値の書き方(生の文字・Unicode の escape)と inspect の深さによらず伏せる' do
    identifiers = {
      'plain' => { channel: 'RoomChannel', pubsub_token: token }.to_json,
      'unicode key' => %({"channel":"RoomChannel","\\u0070ubsub_token":"#{token}"}),
      'fully escaped key' => %({"#{unicode_escape('pubsub_token')}":"#{token}"}),
      'unicode value' => %({"channel":"RoomChannel","pubsub_token":"\\u0054#{token[1..]}"}),
      'fully escaped value' => %({"pubsub_token":"#{unicode_escape(token)}"}),
      'hash inspect' => { 'pubsub_token' => token }.inspect,
      'symbol inspect' => { pubsub_token: token }.inspect
    }
    secrets = [token, token[1..], unicode_escape(token)[6..]]
    leaked = identifiers.flat_map do |name, identifier|
      frame = { command: 'subscribe', identifier: identifier }.to_json
      [frame, frame.inspect, frame.inspect.inspect].each_with_index.filter_map do |form, depth|
        line = described_class.mask("Ignoring message processed after the WebSocket was closed: #{form})")
        "#{name}/#{depth}" if secrets.any? { |secret| line.include?(secret) } || line.exclude?('[FILTERED]')
      end
    end
    expect(leaked).to eq([])
  end

  it 'メールアドレス(@ を Unicode の escape で書いたものも)・JWT・widget の token・封印した暗号文を伏せ、ふつうの行は変えない' do
    jwt = [base64url('{"alg":"HS256","typ":"JWT"}'), base64url({ sub: SecureRandom.hex(6) }.to_json), base64url(SecureRandom.bytes(32))]
          .join('.')
    proof = base64url(SecureRandom.bytes(24))
    sealed = ActiveSupport::MessageEncryptor.new(SecureRandom.bytes(32), cipher: 'aes-256-gcm').encrypt_and_sign('x' * 24)
    samples = {
      'Email sent to agent.name+tag@example.co.jp with subject x' => 'agent.name+tag',
      'contact json-user\\u0040example.test here' => 'json-user',
      %({"email":"lograge-user@example.test","status":200}) => 'lograge-user',
      "jwt #{jwt} end" => jwt.split('.')[1],
      "proof tbwhttp1.#{SecureRandom.hex(8)}.#{proof} rest" => proof,
      "recovery tbwr1.#{SecureRandom.hex(8)}.#{proof}" => proof,
      "sealed #{sealed} tail" => sealed.split('--').first
    }
    expect(samples.select { |line, secret| described_class.mask(line).include?(secret) }.keys).to eq([])
    unchanged = ['Completed 200 OK in 12ms (Views: 1.0ms | ActiveRecord: 2.0ms | Allocations: 1234)',
                 'Performing SendReplyJob (Job ID: 0a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d) from Sidekiq(default) enqueued at 2026-10-29',
                 'Parameters: {"website_token"=>"abc123", "content_type"=>"text", "private"=>false}',
                 'RoomChannel#update_presence', '----- separator -----']
    expect(unchanged.map { |line| described_class.mask(line) }).to eq(unchanged)
  end

  it 'どの式も線形時間で照合する(長い行でも後戻りが膨らまない)' do
    patterns = %i[EMAIL TOKEN_VALUE WIDGET_TOKEN JWT SEALED].index_with { |name| described_class.const_get(name) }
    expect(patterns.reject { |_name, pattern| Regexp.linear_time?(pattern) }.keys).to eq([])
  end

  it 'application の logger の全 logger と、後から足した logger(formatter の無い ::Logger も)は、出す直前に伏せる' do
    expect(Rails.logger.broadcasts).to all(satisfy { |logger| logger.formatter.is_a?(described_class::Formatter) })
    io = StringIO.new
    sinks = [ActiveSupport::Logger.new(io), Logger.new(io)]
    Rails.logger.broadcast_to(*sinks)
    Rails.logger.info(%(direct line to agent-direct@example.test {"pubsub_token":"#{token}"}))
    expect(io.string.lines.size).to eq(2)
    expect(io.string.scan('[FILTERED_EMAIL]').size).to eq(2)
    expect(io.string.scan('"pubsub_token":"[FILTERED]"').size).to eq(2)
    expect([token, 'agent-direct'].select { |secret| io.string.include?(secret) }).to eq([])
  ensure
    sinks&.each { |sink| Rails.logger.stop_broadcasting_to(sink) }
  end

  it 'identifier の引用符が Unicode escape でも token だけを伏せ、後続の属性を残す' do
    identifier = { channel: 'RoomChannel', pubsub_token: token, account_id: 7 }.to_json
    frame = { command: 'subscribe', identifier: identifier }.to_json.gsub('\\"') { '\u0022' }
    expect(JSON.parse(frame).fetch('identifier')).to eq(identifier)

    [frame, frame.inspect, frame.inspect.inspect].each do |form|
      masked = described_class.mask(form)
      expect(masked).not_to include(token)
      expect(masked).to include('[FILTERED]', 'account_id', ':7')
    end
  end
end
