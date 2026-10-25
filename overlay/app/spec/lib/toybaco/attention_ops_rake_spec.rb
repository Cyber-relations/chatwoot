# frozen_string_literal: true

require 'rails_helper'
require 'active_support/testing/stream'
require Rails.root.join('lib/toybaco/growth/billing_receipt')
require Rails.root.join('lib/toybaco/subscription_reconciliation/execution')

Rails.application.load_tasks unless Rake::Task.task_defined?('toybaco:billing_attention_close')

# 置き場所は他の overlay spec(spec/lib/toybaco/*_spec.rb)と揃え、rspec manifest の名簿で固定している。
RSpec.describe Toybaco::Ops::AttentionOps do # rubocop:disable RSpec/SpecFilePathFormat
  include ActiveSupport::Testing::Stream

  let(:at) { Time.utc(2026, 10, 20, 3, 0, 0) }
  let(:subscription) { "sub_AttentionOps#{SecureRandom.hex(4)}" }
  let!(:baseline) { Toybaco::OperatorAction.maximum(:id).to_i }

  # rake の開始・終了の監査行は別の DB セッションで確定させるため、transactional test のロールバックでは消えない
  # (ops_rake_audit_spec と同じ後片付け)。
  after { delete_committed_rows(baseline) }

  around do |example|
    with_modified_env(TOYBACO_OPS_ACTOR: 'ops-lead', TOYBACO_OPS_SOURCE: 'ops-rake-7-1') { travel_to(at) { example.run } }
  end

  def delete_committed_rows(after_id)
    connection = ActiveRecord::Base.connection_db_config.new_connection
    connection.execute('SET session_replication_role = replica')
    connection.execute("DELETE FROM toybaco_operator_actions WHERE id > #{Integer(after_id)}")
  ensure
    connection&.disconnect!
  end

  def new_rows
    Toybaco::OperatorAction.where('id > ?', baseline).order(:id)
  end

  def run_task(name, id, reason, *extras)
    Rake::Task["toybaco:#{name}"].execute(Rake::TaskArguments.new(%i[id reason], [id.to_s, reason, *extras]))
  end

  def billing_event!(state: 'attention', result: 'retry_limit')
    Toybaco::BillingEvent.create!(event_id: "evt_attention#{SecureRandom.hex(6)}", mode: 'test', action: 'subscription_notice',
                                  reference_id: subscription, snapshot: { 'fixture' => true }, payload_digest: 'd' * 64, state: state,
                                  result: result, attempts: 48, next_attempt_at: at, deadline_at: at)
  end

  def sync_request!(state: 'attention', result: 'retry_limit', subscription_id: subscription, account_id: nil)
    Toybaco::SubscriptionSyncRequest.create!(subscription_id: subscription_id, mode: 'test', account_id: account_id, state: state, result: result,
                                             requested_revision: 2, completed_revision: 1, attempts: 48, deadline_at: at - 60,
                                             next_attempt_at: at - 60, next_enqueue_at: at - 60)
  end

  def dispatch!(phase:)
    suffix = SecureRandom.hex(6)
    event = billing_event!(state: 'completed', result: 'renewal_dispatch_accepted')
    operation = Toybaco::RenewalOperation.create!(mode: 'test', subscription_id: subscription, customer_id: "cus_attention#{suffix}",
                                                  invoice_id: "in_attention#{suffix}")
    fact = Toybaco::RenewalInvoiceFact.create!(billing_event_id: event.id, renewal_operation_id: operation.id, event_id: event.event_id,
                                               event_type: 'invoice.payment_failed', mode: 'test', subscription_id: subscription,
                                               customer_id: operation.customer_id, invoice_id: operation.invoice_id,
                                               payload_digest: 'd' * 64, attempt_count: 1, event_created_at: at)
    Toybaco::GrowthRenewalDispatch.create!(renewal_operation_id: operation.id, requested_fact_id: fact.id, state: 'attention', phase: phase,
                                           result: 'stop_attention', deadline_at: at, next_attempt_at: at, next_enqueue_at: at)
  end

  def opening_request!(onboarding_state:)
    account = create(:account)
    owner = create(:user, account: account, role: :administrator)
    Toybaco::OpeningRequest.create!(mode: 'test', session_id: "cs_test_attention#{SecureRandom.hex(6)}", state: 'account_ready',
                                    deadline_at: at, subscription_id: "sub_opening#{SecureRandom.hex(6)}", contract_digest: 'c' * 64,
                                    account_id: account.id, owner_id: owner.id, account_ready_at: at - 2.days,
                                    onboarding_state: onboarding_state, onboarding_attempts: 48)
  end

  describe 'toybaco:billing_attention_close' do
    it '確認待ちの受付を operator_closed で閉じ、理由と実行者を監査行と受付の recovery_log に同じ transaction で残す' do
      row = billing_event!
      expect { run_task('billing_attention_close', row.id, 'foreign') }.to output(
        "TOYBACO_ATTENTION_OPS kind=billing-event id=#{row.id} action=close reason=foreign state=completed " \
        "previous_state=attention previous_result=retry-limit\n"
      ).to_stdout
      expect(row.reload.attributes.slice('state', 'result', 'completed_at')).to eq('state' => 'completed', 'result' => 'operator_closed',
                                                                                   'completed_at' => at)
      expect(row.recovery_log).to eq([{ 'action' => 'operator_close', 'reason' => 'foreign', 'actor' => 'ops-lead',
                                        'closed_at' => at.iso8601, 'previous_result' => 'retry_limit', 'previous_attempts' => 48 }])
      expect(new_rows.pluck(:actor_kind, :actor_id, :action, :result, :source, :target_type, :target_id)).to eq(
        [['rake', 'ops-lead', 'rake.toybaco:billing_attention_close', 'started', 'ops-rake-7-1', nil, nil],
         ['rake', 'ops-lead', 'attention.billing_event.close.foreign', 'ok', 'ops-rake-7-1', 'Toybaco::BillingEvent', row.id],
         ['rake', 'ops-lead', 'rake.toybaco:billing_attention_close', 'ok', 'ops-rake-7-1', nil, nil]]
      )
      params = { 'id' => row.id, 'reason' => 'foreign', 'state' => 'attention', 'result' => 'retry_limit' }
      expect(new_rows.second.params_digest).to eq(Toybaco::Ops::Audit.params_digest(params))
      expect(Toybaco::Growth::PaymentDispatch.due?(row, at + 1.day)).to be(false)
    end

    it '確認待ちでない・無い行と、形の合わない引数は書かずに止め、開始・終了の監査行は failed になる' do
      done = billing_event!(state: 'completed', result: 'subscription_accepted')
      expect { run_task('billing_attention_close', done.id, 'foreign') }.to raise_error(SystemExit)
        .and output("TOYBACO_ATTENTION_OPS kind=billing-event id=#{done.id} result=refused reason=not-attention\n").to_stderr
      expect(done.reload.attributes.slice('state', 'result', 'recovery_log')).to eq('state' => 'completed', 'result' => 'subscription_accepted',
                                                                                    'recovery_log' => [])
      row = billing_event!
      [[row.id.to_s, 'because'], %w[0 foreign], ["#{row.id}x", 'foreign'], [row.id.to_s, 'foreign', 'extra']].each do |id, reason, *extras|
        expect { run_task('billing_attention_close', id, reason, *extras) }.to raise_error(SystemExit).and output(/_ABORT reason=/).to_stderr
      end
      expect { run_task('billing_attention_close', Toybaco::BillingEvent.maximum(:id) + 1, 'foreign') }
        .to raise_error(SystemExit).and output(/reason=not-found/).to_stderr
      expect(row.reload.state).to eq('attention')
      expect(new_rows.where.not(action: 'rake.toybaco:billing_attention_close')).to be_empty
      expect(new_rows.pluck(:result).tally).to eq('started' => 6, 'failed' => 6)
    end
  end

  describe 'toybaco:sync_attention_close' do
    it '購読照合の確認待ちを completed(operator_closed)で閉じ、Free 復帰の停止を再試行している行は閉じない' do
      row = sync_request!
      expect { run_task('sync_attention_close', row.id, 'handled') }
        .to output(/kind=sync-request id=#{row.id} action=close reason=handled state=completed/).to_stdout
      expect(row.reload.attributes.slice('state', 'result', 'completed_revision', 'completed_at'))
        .to eq('state' => 'completed', 'result' => 'operator_closed', 'completed_revision' => 1, 'completed_at' => at)
      expect(new_rows.second.action).to eq('attention.sync_request.close.handled')

      held = sync_request!(subscription_id: "#{subscription}held")
      allow(Toybaco::SubscriptionReconciliation).to receive(:suspension_due?).and_return(true)
      expect { run_task('sync_attention_close', held.id, 'handled') }.to raise_error(SystemExit).and output(/reason=suspension-due/).to_stderr
      expect(held.reload.state).to eq('attention')
    end
  end

  describe 'toybaco:opening_attention_close' do
    it '開通後の初期設定の確認待ちを ready で閉じ、確認待ちでない要求は書かずに止める' do
      row = opening_request!(onboarding_state: 'attention')
      expect { run_task('opening_attention_close', row.id, 'handled') }.to output(
        "TOYBACO_ATTENTION_OPS kind=opening-request id=#{row.id} action=close reason=handled state=ready " \
        "previous_state=attention previous_result=none\n"
      ).to_stdout
      expect(row.reload.attributes.slice('state', 'onboarding_state')).to eq('state' => 'account_ready', 'onboarding_state' => 'ready')
      expect(new_rows.second.action).to eq('attention.opening_request.close.handled')
      pending_row = opening_request!(onboarding_state: 'pending')
      expect { run_task('opening_attention_close', pending_row.id, 'handled') }
        .to raise_error(SystemExit).and output(/reason=not-attention/).to_stderr
      expect(pending_row.reload.onboarding_state).to eq('pending')
    end
  end

  describe 'toybaco:renewal_attention_close' do
    it '更新請求の処理の確認待ちを idle(phase はそのまま)で閉じ、更新の障壁から外す' do
      row = dispatch!(phase: 'received')
      expect(Toybaco::Growth::RenewalDispatch.blocked?('test', subscription, now: at)).to be(true)
      expect { run_task('renewal_attention_close', row.id, 'handled') }
        .to output(/kind=renewal-dispatch id=#{row.id} action=close reason=handled state=idle/).to_stdout
      expect(row.reload.attributes.slice('state', 'phase', 'result')).to eq('state' => 'idle', 'phase' => 'received', 'result' => 'operator_closed')
      expect(Toybaco::Growth::RenewalDispatch.blocked?('test', subscription, now: at)).to be(false)
      expect(Toybaco::Growth::RenewalDispatch.due?(row, at + 1.day)).to be(false)
    end

    it '店舗が今も持つ購読の未完の phase の行は、同じ請求の更新を再開できなくなるので書かずに止める' do
      account = create(:account)
      account.update!(internal_attributes: { 'toybaco_subscription_id' => subscription })
      rows = %w[received due_waiting provider_closed].map { |phase| dispatch!(phase: phase) }
      rows.each do |row|
        expect { run_task('renewal_attention_close', row.id, 'handled') }
          .to raise_error(SystemExit).and output(/kind=renewal-dispatch id=#{row.id} result=refused reason=current-unfinished/).to_stderr
      end
      expect(rows.map { |row| row.reload.values_at(:state, :phase) }).to eq([%w[attention received], %w[attention due_waiting],
                                                                             %w[attention provider_closed]])
      account.update!(internal_attributes: { 'toybaco_subscription_id' => "#{subscription}next" })
      expect { run_task('renewal_attention_close', rows.first.id, 'handled') }.to output(/action=close reason=handled state=idle/).to_stdout
    end

    it 'grace_ready の行と、未完の coordinator がある行は書かずに止める' do
      grace = dispatch!(phase: 'grace_ready')
      expect { run_task('renewal_attention_close', grace.id, 'handled') }.to raise_error(SystemExit).and output(/reason=grace-ready/).to_stderr
      held = dispatch!(phase: 'due_waiting')
      Toybaco::GrowthRenewalCoordinator.create!(account_id: create(:account).id, renewal_operation_id: held.renewal_operation_id,
                                                operation_id: 'a' * 64, receipt_hash: 'b' * 64, receipt: { 'fixture' => true },
                                                phase: 'waiting', due_at: at - 60)
      expect { run_task('renewal_attention_close', held.id, 'handled') }.to raise_error(SystemExit).and output(/reason=coordinator-pending/).to_stderr
      expect([grace.reload.state, held.reload.state]).to eq(%w[attention attention])
    end
  end

  # 照合の実行(Execution)と受付(request!)は外側の transaction を拒むため、この 2 つは transaction なしで流し、作った行を消す。
  describe '照合を始め直す(外側の transaction を拒む照合)' do
    self.use_transactional_tests = false

    after do
      Toybaco::SubscriptionSyncRequest.where(subscription_id: subscription).delete_all
      Account.where(id: created_stores).destroy_all
    end

    let(:created_stores) { [] }

    def store!(subscription_id = nil)
      attributes = subscription_id ? { 'toybaco_subscription_id' => subscription_id } : {}
      create(:account, internal_attributes: attributes).tap { |account| created_stores << account.id }
    end

    describe 'toybaco:sync_attention_retry' do
      it '確認待ちから始め直し(revision を進めて re-arm)、照合の job を積み、照合が再び走る' do
        row = sync_request!
        line = "TOYBACO_ATTENTION_OPS kind=sync-request id=#{row.id} action=retry reason=fixed state=pending " \
               "previous_state=attention previous_result=retry-limit previous_account=none owner=none revision=3 enqueued=true\n"
        expect { run_task('sync_attention_retry', row.id, 'fixed') }
          .to have_enqueued_job(Toybaco::SubscriptionReconciliationJob).with(row.id).and output(line).to_stdout
        expect(row.reload.attributes.slice('state', 'result', 'attempts', 'requested_revision', 'deadline_at', 'next_attempt_at'))
          .to eq('state' => 'pending', 'result' => nil, 'attempts' => 0, 'requested_revision' => 3, 'deadline_at' => at + 1.day,
                 'next_attempt_at' => at)
        expect(new_rows.second.action).to eq('attention.sync_request.retry.fixed')
        # 照合が再び走る(店舗がまだ無い購読なので、店舗の作成を待つ 1 回目の試行になる)。
        Toybaco::SubscriptionReconciliation::Execution.new(row, now: at, environment: { 'TOYBACO_STRIPE_MODE' => 'test' }).call
        expect(row.reload.attributes.slice('state', 'result', 'attempts')).to eq('state' => 'pending', 'result' => 'not_provisioned', 'attempts' => 1)
      end

      it '始め直しの理由は fixed / transient / rebind だけで、確認待ちでない要求は書かずに止める' do
        row = sync_request!(state: 'pending', result: 'not_provisioned')
        expect { run_task('sync_attention_retry', row.id, 'foreign') }
          .to raise_error(SystemExit).and output(/reason=reason-invalid allowed=fixed\|transient/).to_stderr
        expect { run_task('sync_attention_retry', row.id, 'transient') }.to raise_error(SystemExit).and output(/reason=not-attention/).to_stderr
        expect(row.reload.attributes.slice('state', 'requested_revision')).to eq('state' => 'pending', 'requested_revision' => 2)
      end

      it '要求の店舗が今の唯一の店舗でなければ止め(account-moved)、rebind で今の店舗に結び付け直して照合する' do
        store_a = store!
        store_b = store!(subscription)
        row = sync_request!(account_id: store_a.id)
        expect { run_task('sync_attention_retry', row.id, 'fixed') }
          .to raise_error(SystemExit).and output(/kind=sync-request id=#{row.id} result=refused reason=account-moved/).to_stderr
        expect(row.reload.values_at(:state, :account_id, :requested_revision)).to eq(['attention', store_a.id, 2])
        expect { run_task('sync_attention_retry', row.id, 'rebind') }
          .to output(/reason=rebind state=pending .* previous_account=#{store_a.id} owner=#{store_b.id} revision=3 enqueued=true\n\z/).to_stdout
        expect(row.reload.values_at(:state, :account_id, :requested_revision)).to eq(['pending', nil, 3])
        params = { 'id' => row.id, 'reason' => 'rebind', 'state' => 'attention', 'result' => 'retry_limit',
                   'previous_account_id' => store_a.id, 'owner' => store_b.id }
        expect(new_rows.find_by!(action: 'attention.sync_request.retry.rebind').params_digest).to eq(Toybaco::Ops::Audit.params_digest(params))
        allow(Toybaco::StoreFulfillment).to receive(:synchronize).and_return('payment_pending')
        Toybaco::SubscriptionReconciliation::Execution.new(row, client: Object.new, now: at, environment: { 'TOYBACO_STRIPE_MODE' => 'test' }).call
        expect(Toybaco::StoreFulfillment).to have_received(:synchronize).with(store_b, hash_including(subscription_id: subscription))
        expect(row.reload.values_at(:state, :account_id, :result)).to eq(['completed', store_b.id, 'payment_pending'])
      end

      it '今も 2 店舗がその購読を持つ時は rebind も止める(multiple-owners)' do
        stores = [store!(subscription), store!(subscription)]
        row = sync_request!(account_id: stores.first.id)
        expect { run_task('sync_attention_retry', row.id, 'rebind') }
          .to raise_error(SystemExit).and output(/kind=sync-request id=#{row.id} result=refused reason=multiple-owners/).to_stderr
        expect { run_task('sync_attention_retry', row.id, 'transient') }
          .to raise_error(SystemExit).and output(/reason=account-moved/).to_stderr
        expect(row.reload.values_at(:state, :account_id, :requested_revision)).to eq(['attention', stores.first.id, 2])
      end
    end

    describe 'toybaco:sync_subscription' do
      it '確認待ちの要求は再開せず、監査付きで始め直す rake を案内する' do
        row = sync_request!
        with_modified_env(TOYBACO_SUBSCRIPTION_RECONCILIATION_ENABLED: 'true', TOYBACO_STRIPE_MODE: 'test') do
          expect { Rake::Task['toybaco:sync_subscription'].execute(Rake::TaskArguments.new([:subscription_id], [subscription])) }.to output(
            "契約照合: receipt=#{row.id} state=attention\n" \
            "契約照合: 確認待ちのため再開しません。rake \"toybaco:sync_attention_retry[#{row.id},fixed|transient]\" で始め直してください。\n"
          ).to_stdout
        end
        expect(row.reload.attributes.slice('state', 'requested_revision')).to eq('state' => 'attention', 'requested_revision' => 2)
      end
    end
  end
end
