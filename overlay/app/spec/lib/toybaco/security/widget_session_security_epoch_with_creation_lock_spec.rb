# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe Toybaco::Security::WidgetSessionSecurityEpoch, '.with_creation_lock' do
  self.use_transactional_tests = false

  let(:epoch) { described_class }
  let(:sessions) { Toybaco::Security::WidgetHttpSession }
  let(:widget) { create(:channel_widget) }
  let(:cutover) { Time.utc(2026, 11, 4, 10) }
  let(:configs) { InstallationConfig.where(name: epoch::CONFIG_NAME) }
  let(:parent) { create_parent }
  let(:code) { sessions.new(parent).handoff }
  let(:intent) { SecureRandom.hex(32) }
  let(:sync) { Struct.new(:workers, :ready, :proceed, :clock).new([], Queue.new, Queue.new, cutover) }

  before do
    configs.delete_all
    allow(epoch).to receive(:lower_bound).and_return(cutover - 1.day)
    allow(Time).to receive(:now) { Thread.current[:widget_creation_time] || sync.clock }
    widget
    parent
    code
    intent
  end

  after do
    sync.workers.each { |worker| worker.kill if worker.alive? }
    sync.workers.each(&:join)
    configs.delete_all
    rows = Toybaco::WidgetSessionRecord.where(inbox_id: widget.inbox.id)
    Toybaco::WidgetHandoff.where(widget_session_record_id: rows.select(:id)).delete_all
    rows.delete_all
    widget.account.destroy!
  end

  def create_parent
    link = create(:contact_inbox, inbox: widget.inbox, contact: create(:contact, account: widget.account))
    Toybaco::WidgetSessionRecord.create!(parent_attributes(link))
  end

  def parent_attributes(link)
    {
      contact_inbox: link, inbox_id: widget.inbox.id, created_at: cutover - 1.minute,
      secret_digest: sessions.digest(SecureRandom.hex(32)), link_digest: sessions.link_digest(link),
      bootstrap_digest: SecureRandom.hex(32), bootstrap_expires_at: cutover + 1.minute,
      rotated_at: cutover - 1.minute, expires_at: cutover + 1.day
    }
  end

  def request
    ActionDispatch::Request.new(Rack::MockRequest.env_for(
                                  'https://chatwoot.test/api/v1/widget/http_session',
                                  'HTTP_ORIGIN' => 'https://chatwoot.test', 'HTTP_SEC_FETCH_SITE' => 'same-origin', 'HTTP_X_TOYBACO_WIDGET' => '1'
                                ))
  end

  def start_connection(at: nil, &)
    pid = Queue.new
    worker = Thread.new do
      Thread.current.report_on_exception = false
      Thread.current[:widget_creation_time] = at
      InstallationConfig.connection_pool.with_connection { |connection| run_connection(connection, pid, &) }
    end
    sync.workers << worker
    [worker, Timeout.timeout(8) { pid.pop }]
  end

  def run_connection(connection, pid)
    connection.transaction do
      connection.execute("SET LOCAL lock_timeout = '5s'")
      pid << connection.select_value('SELECT pg_backend_pid()').to_i
      yield
    end
  end

  def await_result(worker)
    raise 'widget cutover worker timed out' unless worker.join(8)

    worker.value
  end

  def pause_insert(model)
    allow(model).to receive(:create!).and_wrap_original do |original, *args|
      sync.ready << true
      sync.proceed.pop
      original.call(*args)
    end
  end

  def wait_until_blocked(worker, pid, blocker)
    Timeout.timeout(4) do
      loop do
        unless worker.alive?
          worker.value
          raise 'worker completed without waiting for the cutover lock'
        end

        waiting = InstallationConfig.uncached do
          InstallationConfig.connection.select_values("SELECT unnest(pg_blocking_pids(#{Integer(pid)}))").map(&:to_i)
        end
        break if waiting.include?(blocker)

        sleep 0.01
      end
    end
  end

  def cutover_while_creating(model, creator_at: cutover + 1.second, cutover_at: cutover + 2.seconds, expected_at: cutover_at, &)
    pause_insert(model)
    creator, creator_pid = start_connection(at: creator_at, &)
    await_ready
    writer, writer_pid = start_connection { epoch.advance! }
    wait_until_blocked(writer, writer_pid, creator_pid)
    # Without serialization the writer samples the old clock while creation
    # is paused, and the later child can retain the pre-cutover binding.
    resume_at(cutover_at)
    result = await_result(creator)
    expect(await_result(writer)).to eq([expected_at, true])
    result
  end

  def await_ready
    Timeout.timeout(8) { sync.ready.pop }
  end

  def resume_at(time)
    sync.clock = time
    sync.proceed << true
  end

  it 'waits for a validated handoff child to commit before sampling the cutoff' do
    child, = cutover_while_creating(Toybaco::WidgetSessionRecord) do
      sessions.consume(request, widget, code: code, intent: intent)
    end
    expect(child.record.contact_inbox_id).to eq(parent.contact_inbox_id)
    expect(child.record.reload.created_at).to eq(cutover + 1.second)
    expect(child.record).not_to be_current
    token = sessions.recovery_token(child.record, expires_at: cutover + 1.hour)
    expect { sessions.recovery(token, widget) }.to raise_error(ActiveRecord::RecordNotFound)
    expect { sessions.consume(request, widget, code: code, intent: intent) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  %i[bootstrap bootstrap_ephemeral].each do |entrypoint|
    it "waits for #{entrypoint} creation to commit before retiring it" do
      cutover_while_creating(Toybaco::WidgetSessionRecord) do
        sessions.public_send(entrypoint, request, widget, intent: intent)
      end
      created = Toybaco::WidgetSessionRecord.where(inbox_id: widget.inbox.id).where.not(id: parent.id).sole
      expect(created.created_at).to eq(cutover + 1.second)
      expect(created).not_to be_current
    end
  end

  { 'popout' => :consume, 'recovery' => :recover }.each do |kind, entrypoint|
    it "waits for #{kind} grant issuance and denies its use after cutover" do
      grant = cutover_while_creating(Toybaco::WidgetHandoff) { sessions.new(parent).handoff(kind: kind) }
      expect do
        sessions.public_send(entrypoint, request, widget, code: grant, intent: intent)
      end.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  context 'when the creator clock is ahead of the cutover clock' do
    let(:creator_time) { cutover + Rational(1, 5) }
    let(:cutover_time) { cutover + Rational(1, 10) }
    let(:expected_cutoff) { creator_time + Rational(1, 1_000_000) }

    def cutover_behind_creator(model, &)
      cutover_while_creating(model, creator_at: creator_time, cutover_at: cutover_time, expected_at: expected_cutoff, &)
    end

    it 'retires the committed child even though its timestamp is later than the cutover clock' do
      child, = cutover_behind_creator(Toybaco::WidgetSessionRecord) do
        sessions.consume(request, widget, code: code, intent: intent)
      end
      expect(child.record.reload.created_at).to eq(creator_time)
      expect(child.record.contact_inbox_id).to eq(parent.contact_inbox_id)
      expect(parent.reload).to be_retired
      expect(child.record).to be_retired
      expect(child.record).not_to be_current
      token = sessions.recovery_token(child.record, expires_at: cutover + 1.hour)
      expect { sessions.recovery(token, widget) }.to raise_error(ActiveRecord::RecordNotFound)
      expect { sessions.consume(request, widget, code: code, intent: intent) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'covers the session timestamp even when no later handoff was created' do
      cutover_behind_creator(Toybaco::WidgetSessionRecord) { sessions.bootstrap_ephemeral(request, widget, intent: intent) }
      created = Toybaco::WidgetSessionRecord.where(inbox_id: widget.inbox.id).where.not(id: parent.id).sole
      expect(created.created_at).to eq(creator_time)
      expect(created).to be_retired
      expect(created).not_to be_current
    end

    { 'popout' => :consume, 'recovery' => :recover }.each do |kind, entrypoint|
      it "covers the later #{kind} grant timestamp and denies redemption after commit" do
        grant_code = cutover_behind_creator(Toybaco::WidgetHandoff) { sessions.new(parent).handoff(kind: kind) }
        grant = Toybaco::WidgetHandoff.find_by!(code_digest: sessions.digest(grant_code))
        expect(grant.created_at).to eq(creator_time)
        expect(grant.created_at).to be < epoch.effective
        expect(grant.expires_at).to be > cutover_time
        expect(parent.reload).to be_retired
        expect do
          sessions.public_send(entrypoint, request, widget, code: grant_code, intent: intent)
        end.to raise_error(ActiveRecord::RecordNotFound)
        expect(grant.reload.consumed_at).to be_nil
      end
    end
  end

  def hold_cutover
    allow(epoch).to receive(:save_cutover!).and_wrap_original do |original, *args|
      result = original.call(*args)
      sync.ready << true
      sync.proceed.pop
      result
    end
    start_connection(at: cutover + 2.seconds) { epoch.advance! }
  end

  def denied_creation
    yield
    :unexpected_access
  rescue ActiveRecord::RecordNotFound
    :retired
  end

  it 'waits for an already running cutover, then revalidates the parent before creating a child' do
    count = Toybaco::WidgetSessionRecord.count
    writer, writer_pid = hold_cutover
    await_ready
    creator, creator_pid = start_connection(at: cutover + 3.seconds) do
      denied_creation { sessions.consume(request, widget, code: code, intent: intent) }
    end
    wait_until_blocked(creator, creator_pid, writer_pid)
    sync.proceed << true
    expect(await_result(writer)).to eq([cutover + 2.seconds, true])
    expect(await_result(creator)).to eq(:retired)
    expect(Toybaco::WidgetSessionRecord.count).to eq(count)
    expect(Toybaco::WidgetHandoff.find_by!(code_digest: sessions.digest(code)).consumed_at).to be_nil
  end
end
