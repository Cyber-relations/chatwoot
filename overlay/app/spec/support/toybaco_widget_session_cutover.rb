# frozen_string_literal: true

RSpec.shared_context 'with the widget session security cutover task' do
  include ActiveSupport::Testing::TimeHelpers

  # The audit wrapper has its own committed-connection specs. Keep this suite's
  # cutover/session data in the example transaction, without isolated audit rows.
  before { allow(Toybaco::Ops::Audit).to receive(:around).and_yield }

  def invoke_widget_cutover(*)
    task = Rake::Task['toybaco:widget_session_security_cutover']
    task.reenable
    task.invoke(*)
  end

  def run_widget_cutover(at, recorded_at: at, status: 'advanced')
    expected = "TOYBACO_WIDGET_SESSION_SECURITY_CUTOVER=#{recorded_at.getutc.iso8601(6)}\n" \
               "Widget session security cutover #{status}.\n"
    travel_to(at, with_usec: true) do
      expect { invoke_widget_cutover }.to output(expected).to_stdout
    end
  end
end
