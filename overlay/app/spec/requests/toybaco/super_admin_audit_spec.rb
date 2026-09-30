# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'SuperAdmin 操作の監査', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:store_name) { '秘密の花屋テスト店' }
  let(:owner_email) { 'owner-pii@example.invalid' }
  let(:account) { create(:account, name: store_name, status: :suspended) }
  let!(:baseline) { Toybaco::OperatorAction.maximum(:id).to_i }
  # controller を通さずにフックのトランザクション部分だけを動かすための入れ物。
  let(:hook) do
    Class.new do
      include Toybaco::Ops::SuperAdminAudit
      public :toybaco_operator_transaction
    end.new
  end

  before { sign_in_admin_with_mfa(super_admin) }

  # failed は別の DB セッションで確定させるため、transactional test のロールバックでは消えない。
  after { delete_committed_rows(baseline) }

  def new_rows
    Toybaco::OperatorAction.where('id > ?', baseline).order(:id)
  end

  # 別セッションで確定した監査行の後片付け。監査表は追記専用トリガで DELETE を拒むため、test DB の postgres(superuser)で
  # session_replication_role = replica にしてトリガを止めてから消す。本番のアプリユーザーは superuser ではないので効かない。
  def delete_committed_rows(after_id)
    connection = ActiveRecord::Base.connection_db_config.new_connection
    connection.execute('SET session_replication_role = replica')
    connection.execute("DELETE FROM toybaco_operator_actions WHERE id > #{Integer(after_id)}")
  ensure
    connection&.disconnect!
  end

  # 店舗名は account の中、メールアドレスは Administrate が読まない別の引数に置き、どちらも digest だけに入ることを確かめる。
  def update_params(status)
    { account: { name: store_name, locale: account.locale, status: status }, note: owner_email }
  end

  def update_digest(id, status)
    Toybaco::Ops::Audit.params_digest(
      { 'account' => { 'name' => store_name, 'locale' => account.locale, 'status' => status }, 'note' => owner_email, 'id' => id.to_s }
    )
  end

  def request_id
    response.headers['X-Request-Id']
  end

  describe '店舗(SuperAdmin::AccountsController)' do
    it '更新は操作と同じトランザクションで ok の 1 行を残し、店舗名・メールアドレスの生値は digest 以外の列に入らない' do
      patch "/super_admin/accounts/#{account.id}", params: update_params('active')
      expect(response).to have_http_status(:redirect)
      expect(account.reload.status).to eq('active')
      expect(request_id).to match(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/)
      expect(new_rows.sole).to have_attributes(
        actor_kind: 'super_admin', actor_id: super_admin.id.to_s, action: 'super_admin.account.update', target_type: 'Account',
        target_id: account.id, result: 'ok', source: request_id, params_digest: update_digest(account.id, 'active')
      )
      expect(new_rows.sole.attributes.except('params_digest').values.join("\n")).not_to include(store_name, owner_email)
    end

    it '存在しない店舗は 404 になり、対象なしの failed を 1 行残す' do
      missing = Account.maximum(:id).to_i + 1000
      patch "/super_admin/accounts/#{missing}", params: update_params('active')
      expect(response).to have_http_status(:not_found)
      expect(new_rows.sole).to have_attributes(
        actor_id: super_admin.id.to_s, action: 'super_admin.account.update', target_type: nil, target_id: nil, result: 'failed',
        source: request_id, params_digest: update_digest(missing, 'active')
      )
    end

    it '監査行を書けなければ店舗の変更も残らず、failed だけを別の DB セッションで残す' do
      allow(Toybaco::OperatorAction).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'audit insert blocked')
      patch "/super_admin/accounts/#{account.id}", params: update_params('active')
      expect(response).to have_http_status(:internal_server_error)
      expect(account.reload.status).to eq('suspended')
      expect(account.internal_attributes).not_to include('toybaco_billing_suspended' => false)
      expect(new_rows.pluck(:action, :target_id, :result)).to eq([['super_admin.account.update', account.id, 'failed']])
    end

    it '削除は started を別の DB セッションで先に書き、削除ジョブの登録の後に ok を書く' do
      delete "/super_admin/accounts/#{account.id}"
      expect(response).to have_http_status(:redirect)
      expect(DeleteObjectJob).to have_been_enqueued.with(account)
      expect(new_rows.pluck(:action, :target_type, :target_id, :result, :source)).to eq(
        [['super_admin.account.destroy', 'Account', account.id, 'started', request_id],
         ['super_admin.account.destroy', 'Account', account.id, 'ok', request_id]]
      )
    end

    it '削除の started を書けなければ super を呼ばず、削除ジョブも登録しない' do
      connection = instance_double(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter, quote: "'blocked'", disconnect!: nil)
      allow(connection).to receive(:execute).and_raise(ActiveRecord::StatementInvalid, 'audit insert blocked')
      config = instance_double(ActiveRecord::DatabaseConfigurations::HashConfig, new_connection: connection)
      allow(Toybaco::OperatorAction).to receive(:connection_db_config).and_return(config)
      delete "/super_admin/accounts/#{account.id}"
      expect(response).to have_http_status(:internal_server_error)
      expect(DeleteObjectJob).not_to have_been_enqueued
      expect(new_rows).to be_empty
    end

    it '存在しない店舗の削除は 404 になり、対象なしの started と failed を残す' do
      missing = Account.maximum(:id).to_i + 1000
      delete "/super_admin/accounts/#{missing}"
      expect(response).to have_http_status(:not_found)
      expect(new_rows.pluck(:action, :target_id, :result)).to eq(
        [['super_admin.account.destroy', nil, 'started'], ['super_admin.account.destroy', nil, 'failed']]
      )
    end
  end

  describe 'commit の後の例外' do
    # 実際に commit させるため、この例だけ transactional test を外す。作った店舗と管理者はここで消し、
    # 監査行は外側の after(delete_committed_rows)が消す。
    self.use_transactional_tests = false

    after do
      account.destroy!
      super_admin.destroy!
    end

    it 'after_commit が失敗しても、確定済みの ok 行に failed を足さずに 500 を返す' do
      allow(Toybaco::Ops::Audit).to receive(:record!).and_wrap_original do |original, **kwargs|
        original.call(**kwargs).tap { ActiveRecord::Base.current_transaction.after_commit { raise 'after commit boom' } }
      end
      patch "/super_admin/accounts/#{account.id}", params: update_params('active')
      expect(response).to have_http_status(:internal_server_error)
      expect(account.reload.status).to eq('active')
      expect(new_rows.pluck(:action, :result)).to eq([%w[super_admin.account.update ok]])
    end
  end

  describe '外側のトランザクション(prepend の順)' do
    it 'フックの外側(with_lock など)がロールバックしても failed の行は残る' do
      context = { actor_kind: 'super_admin', actor_id: super_admin.id.to_s, action: 'super_admin.account.update', target: account,
                  params: { 'id' => account.id.to_s }, source: 'outer-lock' }
      expect do
        account.with_lock { hook.toybaco_operator_transaction(context) { raise ArgumentError, 'boom' } }
      end.to raise_error(ArgumentError, 'boom')
      expect(new_rows.pluck(:action, :target_id, :result, :source)).to eq([['super_admin.account.update', account.id, 'failed', 'outer-lock']])
    end
  end

  describe '失敗の行も書けないとき' do
    it '書き込みの例外が、元の例外を cause に持って外へ出る' do
      context = { actor_kind: 'super_admin', actor_id: super_admin.id.to_s, action: 'super_admin.account.update', target: account,
                  params: { 'id' => account.id.to_s }, source: 'cause-check' }
      allow(Toybaco::Ops::Audit).to receive(:record_isolated!).and_raise(ActiveRecord::StatementInvalid, 'isolated insert blocked')
      error = nil
      expect { hook.toybaco_operator_transaction(context) { raise ArgumentError, 'boom' } }
        .to raise_error(ActiveRecord::StatementInvalid, 'isolated insert blocked') { |raised| error = raised }
      expect(error.cause).to be_a(ArgumentError)
      expect(error.cause.message).to eq('boom')
    end
  end

  describe '利用者からの報告(SuperAdmin::SupportReportsController)' do
    let(:owner) { create(:user) }
    let(:report) do
      Toybaco::SupportReport.create!(account: account, user: owner, assignee_id: 1, request_id: SecureRandom.uuid, category: 'product',
                                     knowledge_version: 'fixture', state: 'received', diagnostics_expires_at: 1.day.from_now,
                                     expires_at: 1.day.from_now)
    end

    around { |example| with_modified_env(TOYBACO_SUPPORT_OPERATIONS_OWNER_ID: super_admin.id.to_s) { example.run } }

    it '状態の変更は ok、競合で受け付けなかった変更は rejected として 1 行ずつ残す' do
      patch "/super_admin/toybaco_support/#{report.id}", params: { state: 'reviewing' }
      expect(response).to have_http_status(:redirect)
      first_request = request_id
      patch "/super_admin/toybaco_support/#{report.id}", params: { state: 'reviewing' }
      expect(response).to have_http_status(:conflict)
      expect(report.reload.state).to eq('reviewing')
      digest = Toybaco::Ops::Audit.params_digest({ 'id' => report.id.to_s, 'state' => 'reviewing' })
      expect(new_rows.pluck(:actor_id, :action, :target_type, :target_id, :result, :params_digest, :source)).to eq(
        [[super_admin.id.to_s, 'super_admin.support_report.update', 'Toybaco::SupportReport', report.id, 'ok', digest, first_request],
         [super_admin.id.to_s, 'super_admin.support_report.update', 'Toybaco::SupportReport', report.id, 'rejected', digest, request_id]]
      )
    end
  end
end
