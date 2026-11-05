# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe Toybaco::Security::WidgetSessionSecurityEpoch do
  include_context 'with the widget session security cutover task'

  let(:baseline) { Time.utc(2026, 11, 4, 9) }
  let(:cutover) { baseline + 1.hour }
  let(:configs) { InstallationConfig.where(name: described_class::CONFIG_NAME) }

  before do
    configs.delete_all
    allow(described_class).to receive(:lower_bound).and_return(baseline)
    # Any read through the cached GlobalConfig fails the example (ExpectationNotMetError is not a StandardError).
    allow(GlobalConfig).to receive(:get).and_raise(RSpec::Expectations::ExpectationNotMetError, 'GlobalConfig.get must not be used')
  end

  it 'uses the ENV lower bound before the release task runs' do
    expect(described_class.effective).to eq(baseline)
  end

  it 'persists now in a locked configuration row and emits only the timestamp and advanced phrase' do
    run_widget_cutover(cutover)
    expect(configs.sole).to have_attributes(value: cutover.iso8601(6), locked: true)
    expect(described_class.effective).to eq(cutover)
  end

  it 'retains microsecond precision for the recorded clock time' do
    run_widget_cutover(Time.iso8601('2026-11-04T19:00:00.123456+09:00'))
    expect(configs.sole.value).to eq('2026-11-04T10:00:00.123456Z')
  end

  it 'does not move the stored cutoff backwards on older or repeated invocations' do
    run_widget_cutover(cutover)
    [baseline, cutover, cutover - 1.second].each do |value|
      run_widget_cutover(value, recorded_at: cutover, status: 'stayed')
    end
    expect(configs.sole.value).to eq(cutover.iso8601(6))
    run_widget_cutover(cutover + 1.second)
    expect(described_class.effective).to eq(cutover + 1.second)
  end

  it 'does not let an earlier clock undercut the ENV lower bound' do
    run_widget_cutover(baseline - 1.hour, recorded_at: baseline)
    expect(configs.sole.value).to eq(baseline.iso8601(6))
    expect(described_class.effective).to eq(baseline)
  end

  it 'takes the later value when a later deployment raises the ENV lower bound' do
    run_widget_cutover(cutover)
    allow(described_class).to receive(:lower_bound).and_return(cutover + 1.hour)
    expect(described_class.effective).to eq(cutover + 1.hour)
    expect(configs.sole.value).to eq(cutover.iso8601(6))
  end

  it 'rejects all arguments without changing persisted state' do
    run_widget_cutover(cutover)
    [[cutover.iso8601], ['invalid'], [cutover.iso8601, 'extra']].each do |arguments|
      expect { invoke_widget_cutover(*arguments) }
        .to raise_error(ArgumentError, 'Widget session security cutover takes no arguments')
    end
    expect(configs.sole.value).to eq(cutover.iso8601(6))
  end

  it 'fails closed on malformed stored state instead of silently falling back to ENV' do
    configs.create!(value: 'invalid')
    expect { described_class.effective }.to raise_error(RuntimeError, /ISO 8601/)
    expect { invoke_widget_cutover }.to raise_error(RuntimeError, /ISO 8601/)
    expect(configs.sole.value).to eq('invalid')
  end

  context 'when production is configured through the upstream hash configuration' do
    around do |example|
      previous = described_class.lower_bound
      example.run
    ensure
      described_class.lower_bound = previous
    end

    before do
      allow(described_class).to receive(:lower_bound).and_call_original
      allow(Rails.application.config).to receive(:x).and_return(ActiveSupport::HashWithIndifferentAccess.new)
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))
      allow(described_class).to receive(:asset_precompilation?).and_return(false)
      allow(ENV).to receive(:fetch).and_call_original
    end

    it 'stores the parsed lower bound in the module without writing config.x' do
      allow(ENV).to receive(:fetch).with(described_class::VARIABLE).and_return(baseline.iso8601)
      described_class.configure!
      expect(described_class.lower_bound).to eq(baseline)
      expect(described_class.lower_bound).to be_frozen
      expect(Rails.application.config.x).to be_empty
    end

    it 'rejects a missing value for runtime boot' do
      allow(ENV).to receive(:fetch).with(described_class::VARIABLE).and_yield
      expect { described_class.configure! }.to raise_error(RuntimeError, /must be set/)
    end

    it 'allows a missing value only for asset precompilation' do
      allow(ENV).to receive(:fetch).with(described_class::VARIABLE).and_yield
      allow(described_class).to receive(:asset_precompilation?).and_return(true)
      described_class.configure!
      expect(described_class.lower_bound).to eq(Time.at(0).utc)
      expect(Rails.application.config.x).to be_empty
    end
  end

  context 'with committed state on independent connections' do
    self.use_transactional_tests = false

    after { configs.delete_all }

    def on_another_connection(&)
      thread = Thread.new { InstallationConfig.connection_pool.with_connection(&) }
      raise 'cutover connection timed out' unless thread.join(10)

      thread.value
    ensure
      thread&.kill if thread&.alive?
      thread&.join
    end

    it 'observes a committed cutover on the next check even inside an existing query cache' do
      InstallationConfig.cache do
        expect(InstallationConfig.find_by(name: described_class::CONFIG_NAME)).to be_nil
        expect(described_class.effective).to eq(baseline)
        travel_to(cutover) { on_another_connection { described_class.advance! } }
        expect(described_class.effective).to eq(cutover)
        travel_to(cutover + 1.second) { on_another_connection { described_class.advance! } }
        expect(described_class.effective).to eq(cutover + 1.second)
      end
    end

    it 'serializes concurrent first writers and retains the latest cutoff' do
      ready = Queue.new
      start = Queue.new
      allow(Time).to receive(:now) { Thread.current[:widget_cutover_time] || cutover }
      threads = [cutover, cutover + 1.second].map do |value|
        Thread.new do
          Thread.current[:widget_cutover_time] = value
          InstallationConfig.connection_pool.with_connection do
            ready << true
            start.pop
            described_class.advance!
          end
        end
      end
      Timeout.timeout(10) { 2.times { ready.pop } }
      2.times { start << true }
      threads.each { |thread| raise 'cutover writer timed out' unless thread.join(10) }
      threads.each(&:value)
      expect(configs.count).to eq(1)
      expect(described_class.effective).to eq(cutover + 1.second)
    ensure
      threads&.each { |thread| thread.kill if thread.alive? }
      threads&.each(&:join)
    end
  end
end
