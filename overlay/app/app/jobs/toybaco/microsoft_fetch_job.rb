# frozen_string_literal: true

require_relative '../../../lib/toybaco/connections/microsoft'
require_relative '../../../lib/toybaco/connections/microsoft_sync'
require_relative '../../../lib/toybaco/connections/microsoft_ingest'

class Toybaco::MicrosoftFetchJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform(channel_id)
    @channel = Channel::Email.find_by(id: channel_id)
    return unless fetchable?

    @account_id = @channel.account_id
    @revision = integration.config(@channel).fetch('connection_revision')
    with_lease { fetch }
  rescue Toybaco::Connections::MicrosoftApi::Error => e
    record_error(e.status, reauthorize: e.authorization_failure?)
  rescue IOError, Timeout::Error, SocketError
    record_error(503)
  end

  private

  def integration
    Toybaco::Connections::Microsoft
  end

  def fetchable?
    @channel && integration.connected?(@channel) && integration.allowed?(@channel.account) && !@channel.reauthorization_required?
  end

  def with_lease
    # Expired workers cannot unlock a successor's lease.
    @lease_key = "TOYBACO_MICROSOFT_FETCH::#{@channel.id}"
    @lease_nonce = SecureRandom.hex(24)
    return unless Redis::Alfred.set(@lease_key, @lease_nonce, nx: true, ex: 180)

    begin
      yield
    ensure
      Redis::Alfred.delete_if_equals(@lease_key, @lease_nonce)
    end
  end

  def fetch
    @token = integration.access_token(@channel)
    settings = integration.config(@channel)
    catch(:stale_microsoft_connection) do
      state = Toybaco::Connections::MicrosoftSync.new(api: integration.api).step(
        settings.fetch('sync'), access_token: @token, connected_at: settings.fetch('connected_at')
      ) { |data| with_current_connection { ingest(data) } }
      with_current_connection do
        integration.update_config!(@channel, integration.config(@channel).merge('sync' => state, 'last_error' => nil))
      end
    end
  end

  def with_current_connection
    @channel.with_lock do
      throw :stale_microsoft_connection unless current_connection? && integration.allowed?(@channel.account)
      throw :stale_microsoft_connection unless Redis::Alfred.get(@lease_key) == @lease_nonce

      yield
    end
  end

  def current_connection?
    integration.connected?(@channel) && @channel.account_id == @account_id && integration.config(@channel)['connection_revision'] == @revision
  end

  def ingest(data)
    Toybaco::Connections::MicrosoftIngest.new(@channel, data, api: integration.api, access_token: @token).call
  end

  def record_error(status, reauthorize: false)
    return unless @channel

    @channel.with_lock do
      return unless current_connection?

      @channel.prompt_reauthorization! if reauthorize
      integration.update_config!(@channel, integration.config(@channel).merge(
                                             'last_error' => { 'status' => status, 'observed_at' => Time.now.utc.iso8601 }
                                           ))
    end
  end
end
