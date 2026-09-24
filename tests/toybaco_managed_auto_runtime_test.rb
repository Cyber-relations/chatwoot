# frozen_string_literal: true

unless ENV['TOYBACO_MANAGED_AUTO_LOCAL'] == 'true'
  require 'rails/test_help'
  require 'minitest/mock'
  require 'timeout'
  require 'ostruct'
  require 'factory_bot_rails'
  require Rails.root.join('lib/toybaco/growth/managed_auto_work')
  require Rails.root.join('lib/toybaco/growth/managed_auto_install')
  require Rails.root.join('lib/toybaco/growth/managed_auto_ingress')
  FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)
end

module ToybacoManagedAutoCases
  AUTO = Toybaco::Growth::ManagedAuto
  Work = Toybaco::Growth::ManagedAutoWork
  Install = Toybaco::Growth::ManagedAutoInstall
  Ingress = Toybaco::Growth::ManagedAutoIngress
  Requests = Toybaco::GrowthAutoRequest
  Installations = Toybaco::GrowthAutoInstallation
  Operation = Toybaco::GrowthAiOperation
  Growth = Toybaco::Growth

  def setup
    super
    @old_flag = ENV['TOYBACO_MANAGED_AUTO_ENABLED']
    ENV['TOYBACO_MANAGED_AUTO_ENABLED'] = 'true'
    @old_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @account = create(:account)
    @admin = create(:user, :administrator, account: @account)
    @inbox = create(:inbox, account: @account)
    set_auto_plan('standard')
    Growth::StoreFacts.new(@account).save!({ 'name' => 'Managed fixture', 'hours' => '10時から18時' }, user: @admin)
    @grant = Growth::AiGrants.new(@account).issue!(source: 'pack', source_key: 'managed-auto-test', units: 1,
                                                 starts_at: Time.now.utc - 60, ends_at: Time.now.utc + 1.day)
  end

  def teardown
    Requests.where(account_id: @account.id).delete_all
    Toybaco::GrowthAutoCommand.where(account_id: @account.id).delete_all
    Installations.where(account_id: @account.id).delete_all
    @account.destroy!
    @admin.destroy!
    ActiveJob::Base.queue_adapter = @old_adapter
    ENV['TOYBACO_MANAGED_AUTO_ENABLED'] = @old_flag
    super
  end

  def set_auto_plan(id)
    terms = Toybaco::PlanCatalog.default.definition(id, '2026-09-18.1')
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: id == 'free' ? nil : 'month'))
  end

  def install
    @installation ||= Install.new(@account.id, actor_id: @admin.id).create!(inbox_id: @inbox.id, request_id: SecureRandom.uuid)
  end

  def switch(mode)
    row = install.reload
    Install.new(@account.id, actor_id: @admin.id).change!(mode: mode, generation: row.generation.to_s,
                                                       epoch: row.epoch, request_id: SecureRandom.uuid)
  end

  def incoming(content: '営業時間は？')
    conversation = create(:conversation, account: @account, inbox: @inbox, status: :pending)
    message = create(:message, account: @account, inbox: @inbox, conversation: conversation,
                               message_type: :incoming, private: false, content: content)
    [conversation, message]
  end

  def admit(message)
    Ingress.receive(install.bot_id, { event: :message_created, id: message.id })
    Requests.find_by!(account_id: @account.id, message_id: message.id)
  end

  def complete(request, &block)
    calls = []
    model = Object.new
    model.define_singleton_method(:generate) do |prompt|
      calls << prompt
      block&.call
      { 'action' => 'answer', 'reply' => '10時から18時までです。' }
    end
    Work.new(request, model: model).perform
    calls
  end

  def test_registration_is_draft_exact_replay_and_does_not_replace_any_bot
    row = install
    assert_equal 'draft', row.state
    assert_equal 'draft', Toybaco::AiReplyMode.read_from(@account.reload)
    assert AUTO.current_assignment?(row)
    assert_nil AgentBot.find(row.bot_id).outgoing_url
    repeated = Install.new(@account.id, actor_id: @admin.id).create!(inbox_id: @inbox.id, request_id: row.request_id)
    assert_equal row.id, repeated.id
    assert_raises(AUTO::Invalid) { Install.new(@account.id, actor_id: @admin.id).create!(inbox_id: @inbox.id, request_id: SecureRandom.uuid) }
    assert_equal 1, AgentBot.where(account_id: @account.id).count
  end

  def test_existing_bot_configuration_is_preserved
    legacy = create(:agent_bot, account: @account)
    create(:agent_bot_inbox, inbox: @inbox, agent_bot: legacy)
    assert_raises(AUTO::Invalid) { install }
    assert_empty Installations.where(account_id: @account.id)
    assert_equal legacy.id, AgentBotInbox.find_by!(inbox_id: @inbox.id).agent_bot_id
  end

  def test_registration_rejects_disabled_flag_light_foreign_inbox_and_non_admin
    ENV['TOYBACO_MANAGED_AUTO_ENABLED'] = 'false'
    assert_raises(AUTO::Invalid) { install }
    ENV['TOYBACO_MANAGED_AUTO_ENABLED'] = 'true'
    set_auto_plan('light')
    assert_raises(AUTO::Invalid) { install }
    set_auto_plan('standard')
    assert_raises(ActiveRecord::RecordNotFound) { Install.new(@account.id, actor_id: @admin.id).create!(inbox_id: 0, request_id: SecureRandom.uuid) }
    assert_raises(AUTO::Invalid) { Install.new(@account.id, actor_id: 0).create!(inbox_id: @inbox.id, request_id: SecureRandom.uuid) }
    assert_empty Installations.where(account_id: @account.id)
  end

  def test_registration_rejects_outer_transaction_and_unconfirmed_facts
    assert_raises(AUTO::Invalid) { Account.transaction { install } }
    @account.update!(internal_attributes: @account.internal_attributes.except(Growth::StoreFacts::KEY))
    assert_raises(AUTO::Invalid) { install }
    assert_empty AgentBot.where(account_id: @account.id)
  end

  def test_draft_routes_to_staff_without_model_request
    install
    conversation, message = incoming
    Ingress.receive(install.bot_id, { event: :message_created, id: message.id })
    assert_equal 'open', conversation.reload.status
    assert_empty Requests.where(account_id: @account.id)
  end

  def test_auto_ingress_model_ledger_message_and_delivery_claim_are_one_shot
    switch('auto')
    conversation, message = incoming
    request = admit(message)
    assert_equal request.id, admit(message).id
    calls = complete(request)
    assert_equal 1, calls.size
    assert_equal 'completed', request.reload.state
    operation = Operation.find(request.operation_id)
    assert_equal 'consumed', operation.state
    assert_equal 1, @grant.reload.used
    reply = conversation.messages.find(operation.result_reference.delete_prefix('message:'))
    refute reply.private?
    assert_equal install.bot_id, reply.sender_id
    assert Growth::ReplyDelivery.new(reply).claim!
    refute Growth::ReplyDelivery.new(reply.reload).claim!
    assert_empty complete(request)
    assert_equal 1, conversation.messages.where(message_type: :outgoing).count
  end

  def test_enqueue_failure_is_recovered_by_saved_id
    switch('auto')
    message = nil
    Toybaco::ManagedAutoJob.stub(:perform_later, ->(*) { raise IOError, 'fixture registration lost' }) do
      _, message = incoming
      admit(message)
    end
    request = Requests.find_by!(message_id: message.id)
    assert_equal 'queued', request.state
    assert request.enqueue_after > Time.now.utc
    request.update!(enqueue_after: Time.now.utc - 1)
    assert_difference_jobs(1) { Ingress.enqueue(request) }
    complete(request)
    assert_equal 'completed', request.reload.state
  end

  def assert_difference_jobs(number)
    before = ActiveJob::Base.queue_adapter.enqueued_jobs.size
    yield
    assert_equal before + number, ActiveJob::Base.queue_adapter.enqueued_jobs.size
  end

  def test_stopping_before_start_cancels_without_model_or_charge_and_old_epoch_never_revives
    switch('auto')
    _, message = incoming
    request = admit(message)
    switch('stopped')
    assert_equal 'stopped', install.reload.state
    assert_equal 'cancelled', request.reload.state
    switch('auto')
    assert_empty complete(request)
    assert_equal 0, @grant.reload.used
    assert_empty Operation.where(account_id: @account.id)
  end

  def test_stop_during_model_is_pending_then_known_result_releases_without_public_reply
    switch('auto')
    conversation, message = incoming
    request = admit(message)
    complete(request) do
      assert_equal 'started', request.reload.state
      switch('stopped')
      assert_equal 'stopping', install.reload.state
      assert_raises(AUTO::Invalid) { switch('auto') }
    end
    assert_equal 'stopped', install.reload.state
    assert_equal 'cancelled', request.reload.state
    assert_equal 'released', Operation.find(request.operation_id).state
    assert_empty conversation.messages.where(message_type: :outgoing)
    assert_equal 0, @grant.reload.used
  end

  def test_unknown_model_result_is_not_retried_or_expired_and_blocks_retention
    switch('auto')
    _, message = incoming
    request = admit(message)
    model = Object.new
    calls = 0
    model.define_singleton_method(:generate) { |_| calls += 1; raise IOError, 'fixture response lost' }
    Work.new(request, model: model).perform
    assert_equal 'uncertain', request.reload.state
    Work.new(request, model: model).perform
    assert_equal 1, calls
    operation = Operation.find(request.operation_id)
    operation.update!(lease_expires_at: Time.now.utc - 1)
    assert_equal 0, Growth::AiLedger.new(@account).summary['remaining']
    duplicate = Growth::AiLedger.new(@account).reserve(request_key: operation.request_key, kind: operation.kind, context_digest: operation.context_digest)
    assert_equal 'reserved', duplicate['state']
    assert_raises(Growth::InboxRetention::Busy) { AUTO.assert_holdable!(@account.id) }
    retention = Growth::InboxRetention.new(@account)
    assert_raises(Growth::InboxRetention::Busy) { @account.with_lock { retention.send(:install!) } }
    switch('stopped')
    ENV['TOYBACO_MANAGED_AUTO_ENABLED'] = 'false'
    assert_equal 'stopping', install.reload.state
    assert_raises(Growth::InboxRetention::Busy) { AUTO.assert_holdable!(@account.id) }
    assert_equal 'uncertain', request.reload.state
  end

  def test_atomic_message_and_charge_rollback_becomes_uncertain_not_automatic_retry
    switch('auto')
    conversation, message = incoming
    request = admit(message)
    original = Growth::ReplyResult.instance_method(:persist!)
    Growth::ReplyResult.define_method(:persist!) do |*args, **kwargs|
      original.bind_call(self, *args, **kwargs)
      raise IOError, 'fixture after message INSERT'
    end
    complete(request)
    assert_equal 'uncertain', request.reload.state
    assert_equal 'reserved', Operation.find(request.operation_id).state
    assert_equal 0, @grant.reload.used
    assert_empty conversation.messages.where(message_type: :outgoing)
  ensure
    Growth::ReplyResult.define_method(:persist!, original) if original
  end

  def test_new_incoming_during_model_prevents_old_answer
    switch('auto')
    conversation, message = incoming
    request = admit(message)
    newer = nil
    complete(request) do
      newer = create(:message, account: @account, inbox: @inbox, conversation: conversation,
                              message_type: :incoming, private: false, content: '明日の営業時間は？')
    end
    assert_equal 'cancelled', request.reload.state
    assert_equal 'generation_changed', request.reason
    assert_equal 'released', Operation.find(request.operation_id).state
    assert_empty conversation.messages.where(message_type: :outgoing)
    assert conversation.reload.pending?
    assert_equal 0, @grant.reload.used
    following = admit(newer)
    assert_equal 1, complete(following).size
    assert_equal 'completed', following.reload.state
    assert_equal 1, @grant.reload.used
  end

  def test_second_incoming_can_complete_after_first_reply
    switch('auto')
    conversation, message = incoming
    first = admit(message)
    complete(first)
    assert_equal 'completed', first.reload.state
    Growth::AiGrants.new(@account).issue!(source: 'pack', source_key: 'managed-auto-second', units: 1,
                                         starts_at: Time.now.utc - 60, ends_at: Time.now.utc + 1.day)
    newer = create(:message, account: @account, inbox: @inbox, conversation: conversation,
                            message_type: :incoming, private: false, content: '明日の営業時間は？')
    second = admit(newer)
    assert_equal 1, complete(second).size
    assert_equal 'completed', second.reload.state
    assert_equal 'consumed', Operation.find(second.operation_id).state
    assert_equal 2, conversation.messages.where(message_type: :outgoing).count
  end

  def test_older_queued_request_with_tied_timestamp_does_not_open_newer_pending_conversation
    switch('auto')
    conversation, message = incoming
    older = admit(message)
    newer = create(:message, account: @account, inbox: @inbox, conversation: conversation,
                            message_type: :incoming, private: false, content: '明日の営業時間は？', created_at: message.created_at)
    following = admit(newer)
    assert_empty complete(older)
    assert_equal 'cancelled', older.reload.state
    assert conversation.reload.pending?
    assert_equal 'queued', following.reload.state
    assert_equal 1, complete(following).size
    assert_equal 'completed', following.reload.state
  end

  def test_prompt_history_uses_latest_twelve_messages
    switch('auto')
    conversation, first = incoming(content: 'question 0')
    messages = [first]
    12.times do |index|
      messages << create(:message, account: @account, inbox: @inbox, conversation: conversation,
                                   message_type: :incoming, private: false, content: "question #{index + 1}")
    end
    calls = complete(admit(messages.last))
    assert_equal 1, calls.size
    history = JSON.parse(calls.first.fetch('messages').first.fetch('content')).fetch('conversation')
    assert_equal messages.last(12).map(&:content), history.map { |entry| entry.fetch('content') }
    assert_equal 'completed', admit(messages.last).reload.state
  end

  def test_handoff_result_for_superseded_incoming_preserves_new_request
    switch('auto')
    conversation, message = incoming
    request = admit(message)
    newer = nil
    receive = lambda do
      newer = create(:message, account: @account, inbox: @inbox, conversation: conversation,
                               message_type: :incoming, private: false, content: '明日の営業時間は？')
    end
    model = Object.new
    model.define_singleton_method(:generate) do |_|
      receive.call
      { 'action' => 'handoff', 'reply' => '' }
    end
    Work.new(request, model: model).perform
    assert_equal 'cancelled', request.reload.state
    assert_equal 'released', Operation.find(request.operation_id).state
    assert_empty conversation.messages.where(message_type: :outgoing)
    assert conversation.reload.pending?
    assert_equal 'queued', admit(newer).state
  end

  def test_resolved_during_model_releases_result_without_reopening
    switch('auto')
    conversation, message = incoming
    request = admit(message)
    complete(request) { conversation.resolved! }
    assert_equal 'cancelled', request.reload.state
    assert_equal 'released', Operation.find(request.operation_id).state
    assert_equal 'resolved', conversation.reload.status
    assert_empty conversation.messages.where(message_type: :outgoing)
  end

  def test_explicit_stop_before_delivery_keeps_a_private_draft
    switch('auto')
    conversation, message = incoming
    request = admit(message)
    complete(request)
    reply = conversation.messages.where(message_type: :outgoing).sole
    switch('stopped')
    refute Growth::ReplyDelivery.new(reply).claim!
    assert reply.reload.private?
    assert_equal 'held', reply.additional_attributes.dig(Growth::ReplyResult::KEY, 'state')
    assert_equal 'open', conversation.reload.status
  end

  def test_handoff_opens_conversation_without_quota_consumption
    switch('auto')
    conversation, message = incoming
    request = admit(message)
    model = Object.new
    model.define_singleton_method(:generate) { |_| { 'action' => 'handoff', 'reply' => '' } }
    Work.new(request, model: model).perform
    assert_equal 'handoff', request.reload.state
    assert_equal 'released', Operation.find(request.operation_id).state
    assert_equal 0, @grant.reload.used
    assert_equal 'open', conversation.reload.status
    assert conversation.messages.where(message_type: :outgoing).sole.private?
  end

  def test_bot_assignment_aba_invalidates_queued_generation
    switch('auto')
    _, message = incoming
    request = admit(message)
    binding = AgentBotInbox.find_by!(agent_bot_id: install.bot_id)
    binding.update!(status: :inactive)
    binding.update!(status: :active)
    assert_equal 'stopped', install.reload.state
    assert_equal 'cancelled', request.reload.state
    assert_empty complete(request)
  end

  def test_bot_assignment_change_is_rejected_while_model_outcome_unknown
    switch('auto')
    _, message = incoming
    request = admit(message)
    complete(request) { raise IOError, 'fixture unknown' }
    binding = AgentBotInbox.find_by!(agent_bot_id: install.bot_id)
    assert_raises(Growth::InboxRetention::Busy) { binding.update!(status: :inactive) }
    assert_equal 'active', binding.reload.status
  end

  def test_incoming_message_and_durable_request_commit_and_rollback_together
    switch('auto')
    conversation = create(:conversation, account: @account, inbox: @inbox, status: :pending)
    message = nil
    Message.transaction do
      message = create(:message, account: @account, inbox: @inbox, conversation: conversation,
                                 message_type: :incoming, private: false, content: '営業時間は？')
      assert Requests.exists?(account_id: @account.id, message_id: message.id)
      raise ActiveRecord::Rollback
    end
    refute Message.exists?(id: message.id)
    refute Requests.exists?(account_id: @account.id, message_id: message.id)
    message = create(:message, account: @account, inbox: @inbox, conversation: conversation,
                               message_type: :incoming, private: false, content: '営業時間は？')
    assert Requests.exists?(account_id: @account.id, message_id: message.id)
    assert_equal 'queued', Requests.find_by!(message_id: message.id).state
  end

  def test_separate_pg_connections_start_once_and_hold_waits_for_model_result
    switch('auto')
    _, message = incoming
    request = admit(message)
    ready, finish = Queue.new, Queue.new
    model = Object.new
    model.define_singleton_method(:generate) do |_|
      ready << true
      finish.pop
      { 'action' => 'answer', 'reply' => '10時からです。' }
    end
    thread = Thread.new do
      Account.connection_pool.with_connection { Work.new(Requests.find(request.id), model: model).perform }
    end
    Timeout.timeout(5) { ready.pop }
    assert_equal 'started', request.reload.state
    assert_empty complete(request)
    assert_raises(Growth::InboxRetention::Busy) { Growth::InboxRetention.with_fence(@account.id, exclusive: true) { flunk } }
    finish << true
    assert thread.join(5)
    thread.value
    assert_equal 'completed', request.reload.state
    assert_equal 1, @grant.reload.used
  ensure
    finish << true if finish
    thread&.kill&.join if thread&.alive?
  end

  def test_worker_disappearance_after_start_never_releases_lease_or_rearms_model
    switch('auto')
    _, message = incoming
    request = admit(message)
    calls = Queue.new
    model = Object.new
    model.define_singleton_method(:generate) { |_| calls << true; Thread.current.exit }
    thread = Thread.new do
      Account.connection_pool.with_connection { Work.new(Requests.find(request.id), model: model).perform }
    end
    assert thread.join(5)
    assert_equal 1, calls.size
    assert_equal 'started', request.reload.state
    Operation.find(request.operation_id).update!(lease_expires_at: Time.now.utc - 365.days)
    assert_empty complete(request)
    assert_equal 0, Growth::AiLedger.new(@account).summary['remaining']
    assert_raises(Growth::InboxRetention::Busy) { AUTO.assert_holdable!(@account.id) }
    switch('stopped')
    assert_equal 'stopping', install.reload.state
  ensure
    thread&.kill&.join if thread&.alive?
  end

  def test_contract_and_actor_change_restore_do_not_reactivate_old_requests
    switch('auto')
    _, message = incoming
    request = admit(message)
    before = @account.reload.internal_attributes.deep_dup
    @account.update!(internal_attributes: before.merge('toybaco_subscription_id' => 'sub_managed_changed'))
    @account.update!(internal_attributes: before)
    assert_equal 'stopped', install.reload.state
    assert_equal 'cancelled', request.reload.state
    switch('auto')
    _, next_message = incoming
    next_request = admit(next_message)
    member = @account.account_users.find_by!(user_id: @admin.id)
    member.update!(role: :agent)
    member.update!(role: :administrator)
    assert_equal 'stopped', install.reload.state
    assert_equal 'cancelled', next_request.reload.state
    assert_empty complete(next_request)
  end

  def test_normal_contract_and_membership_writers_reject_unknown_model_outcome
    switch('auto')
    _, message = incoming
    request = admit(message)
    complete(request) { raise IOError, 'fixture unknown provider result' }
    attrs = @account.reload.internal_attributes.deep_dup
    assert_raises(Growth::InboxRetention::Busy) do
      @account.update!(internal_attributes: attrs.merge('toybaco_subscription_id' => 'sub_forbidden'))
    end
    assert_equal attrs, @account.reload.internal_attributes
    member = @account.account_users.find_by!(user_id: @admin.id)
    assert_raises(Growth::InboxRetention::Busy) { member.update!(role: :agent) }
    assert_equal 'administrator', member.reload.role
  end

  def test_failed_membership_write_rolls_back_epoch_and_queue_cancellation
    switch('auto')
    _, message = incoming
    request = admit(message)
    epoch = install.reload.epoch
    member = @account.account_users.find_by!(user_id: @admin.id)
    AccountUser.transaction do
      member.update!(role: :agent)
      assert_equal 'stopped', install.reload.state
      raise ActiveRecord::Rollback
    end
    assert_equal 'auto', install.reload.state
    assert_equal epoch, install.epoch
    assert_equal 'queued', request.reload.state
    complete(request)
    assert_equal 'completed', request.reload.state
  end

  def test_conflicting_bot_creation_is_serialized_with_registration
    ready, finish = Queue.new, Queue.new
    thread = Thread.new do
      Account.connection_pool.with_connection do
        AgentBot.transaction do
          create(:agent_bot, account: Account.find(@account.id))
          ready << true
          finish.pop
        end
      end
    end
    Timeout.timeout(5) { ready.pop }
    assert_raises(Growth::InboxRetention::Busy) { install }
    finish << true
    assert thread.join(5)
    thread.value
    assert_raises(AUTO::Invalid) { install }
    assert_equal 1, AgentBot.where(account_id: @account.id).count
    assert_empty Installations.where(account_id: @account.id)
  ensure
    finish << true if finish
    thread&.kill&.join if thread&.alive?
  end

  def test_explicit_auto_binds_the_current_administrator_and_rechecks_actual_membership
    operator = create(:user, :administrator, account: @account)
    row = install.reload
    Install.new(@account.id, actor_id: operator.id).change!(mode: 'auto', generation: row.generation.to_s,
                                                          epoch: row.epoch, request_id: SecureRandom.uuid)
    assert_equal operator.id, install.reload.actor_id
    _, message = incoming
    request = admit(message)
    member = @account.account_users.find_by!(user_id: operator.id)
    # Adversarial fixture bypasses callbacks; admission still rereads the row.
    AccountUser.connection.execute("UPDATE account_users SET role = 0 WHERE id = #{member.id}")
    assert_empty complete(request)
    assert_equal 'cancelled', request.reload.state
    assert_empty Operation.where(account_id: @account.id)
  ensure
    operator&.destroy!
  end

  def test_late_listener_event_from_before_explicit_auto_does_not_start_an_old_message
    install
    conversation, message = incoming
    switch('auto')
    conversation.pending!
    Ingress.receive(install.bot_id, { event: :message_created, id: message.id })
    refute Requests.exists?(account_id: @account.id, message_id: message.id)
    assert_empty Operation.where(account_id: @account.id)
  end

  def test_disabled_flag_routes_new_incoming_to_staff_without_generation
    switch('auto')
    ENV['TOYBACO_MANAGED_AUTO_ENABLED'] = 'false'
    conversation, message = incoming
    assert_equal 'open', conversation.reload.status
    refute Requests.exists?(account_id: @account.id, message_id: message.id)
    assert_empty Operation.where(account_id: @account.id)
  end

  def test_unknown_response_opens_staff_conversation_without_claiming_stop_complete
    switch('auto')
    conversation, message = incoming
    request = admit(message)
    complete(request) { raise IOError, 'fixture provider uncertain' }
    assert_equal 'open', conversation.reload.status
    assert_equal 'uncertain', request.reload.state
    switch('stopped')
    state = AUTO.public_state(install.reload)
    assert_equal 'stopping', state['state']
    assert state['pending']
  end

  def test_new_model_parser_enforces_single_tool_no_free_text_and_handoff_shape
    model = Growth::ManagedAutoModel.new
    envelope = { 'type' => 'message', 'role' => 'assistant', 'stop_reason' => 'tool_use', 'content' => [
      { 'id' => 'tool_fixture', 'type' => 'tool_use', 'name' => 'route_reply', 'input' => { 'action' => 'answer', 'reply' => '10時からです。' } }
    ] }
    assert_equal 'answer', model.parse(JSON.generate(envelope))['action']
    envelope['content'].first['input'] = { 'action' => 'handoff', 'reply' => '未確認の返金額' }
    assert_raises(Growth::DraftModel::Unavailable) { model.parse(JSON.generate(envelope)) }
    envelope['content'] = [{ 'type' => 'text', 'text' => 'unbounded response' }]
    assert_raises(Growth::DraftModel::Unavailable) { model.parse(JSON.generate(envelope)) }
  end
end

unless ENV['TOYBACO_MANAGED_AUTO_LOCAL'] == 'true'
  class ToybacoManagedAutoRuntimeTest < ActionDispatch::IntegrationTest
    include FactoryBot::Syntax::Methods
    include ToybacoManagedAutoCases
    self.use_transactional_tests = false

    def session_request
      Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @admin)) { yield }
    end

    def test_http_registration_rejects_cross_origin_then_registers_initial_draft
      payload = { account_id: @account.id, inbox_id: @inbox.id, request_id: SecureRandom.uuid }
      session_request do
        post '/toybaco/growth/automatic-replies', params: payload, headers: { 'Origin' => 'https://elsewhere.invalid' }, as: :json
      end
      assert_response :forbidden
      refute Installations.exists?(account_id: @account.id)
      session_request do
        post '/toybaco/growth/automatic-replies', params: payload, headers: { 'Origin' => 'http://www.example.com' }, as: :json
      end
      assert_response :success
      assert_equal 'draft', response.parsed_body['state']
      assert_equal @inbox.id, response.parsed_body['inbox_id']
    end

    def test_managed_bot_token_cannot_read_or_write_through_general_account_api
      conversation, = incoming
      bot = AgentBot.find(install.bot_id)
      get "/api/v1/accounts/#{@account.id}/conversations/#{conversation.display_id}", headers: { 'api_access_token' => bot.access_token.token }
      assert_response :unauthorized
    end

    def test_managed_mode_uses_epoch_bound_page_and_old_endpoint_cannot_restart
      install
      session_request do
        put '/toybaco/ai_reply_mode', params: { account_id: @account.id, mode: 'auto' },
                                    headers: { 'Origin' => 'http://www.example.com' }, as: :json
      end
      assert_response :conflict
      assert_equal 'draft', install.reload.state
      session_request { get '/toybaco/growth/automatic-replies', params: { account_id: @account.id } }
      assert_response :success
      assert_includes response.body, 'この窓口で全自動を始める'
      assert_includes response.headers['Content-Security-Policy'], "frame-ancestors 'self'"
    end

    def test_connection_readiness_counts_managed_bot_without_webhook_url
      install
      result = Toybaco::AiReadiness.for_account(@account)
      assert_equal 'configured', result['connection']
      assert_equal 1, result['configured_inboxes']
      assert_equal 'unverified', result['live_verification']
      assert_equal true, result['managed_auto_registered']
    end
  end
end
