# frozen_string_literal: true

require 'rails_helper'

# 置き場所は他の overlay spec(spec/lib/toybaco/*_spec.rb)と揃え、rspec manifest の名簿で固定している。
RSpec.describe Toybaco::Ops::Audit do # rubocop:disable RSpec/SpecFilePathFormat
  let(:context) { { actor_kind: 'rake', actor_id: 'ops-lead', action: 'rake.toybaco:plan_status', source: 'ops-rake-1-1' } }
  let(:valid) { { actor_kind: 'rake', actor_id: 'ops-lead', action: 'rake.toybaco:plan_status', result: 'ok' } }
  let!(:baseline) { Toybaco::OperatorAction.maximum(:id).to_i }

  # record_isolated! と around は別の DB セッションで確定させるため、transactional test のロールバックでは消えない。
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

  describe '.params_digest' do
    it 'ネストしたキーの順序によらず同じ値になり、canonical JSON の SHA-256 と一致する' do
      left = { 'b' => 1, 'a' => { 'y' => [3, { 'q' => 'x', 'p' => nil }], 'x' => true } }
      right = { a: { x: true, y: [3, { p: nil, q: 'x' }] }, b: 1 }
      expect(described_class.params_digest(left)).to eq(Digest::SHA256.hexdigest('{"a":{"x":true,"y":[3,{"p":null,"q":"x"}]},"b":1}'))
      expect(described_class.params_digest(right)).to eq(described_class.params_digest(left))
      expect(described_class.params_digest([{ 'b' => 2, 'a' => 1 }])).to eq(Digest::SHA256.hexdigest('[{"a":1,"b":2}]'))
      expect(described_class.params_digest([2, 1])).not_to eq(described_class.params_digest([1, 2]))
      expect(described_class.params_digest(nil)).to be_nil
      expect { described_class.params_digest('raw') }.to raise_error(ArgumentError)
    end
  end

  describe '.record!' do
    it '引数の生値を保存せず digest だけを残し、呼び出し元のトランザクションに入る' do
      account = create(:account)
      params = { 'account' => { 'name' => '秘密の花屋テスト店', 'email' => 'owner-pii@example.invalid' } }
      row = described_class.record!(**context, target: account, params: params, result: 'ok')
      expect(Toybaco::OperatorAction.find(row.id)).to have_attributes(
        actor_kind: 'rake', actor_id: 'ops-lead', action: 'rake.toybaco:plan_status', target_type: 'Account', target_id: account.id,
        result: 'ok', source: 'ops-rake-1-1', params_digest: described_class.params_digest(params)
      )
      expect(Toybaco::OperatorAction.find(row.id).attributes.values.join("\n")).not_to include('秘密の花屋テスト店', 'owner-pii@example.invalid')
      ActiveRecord::Base.transaction do
        described_class.record!(**context, result: 'failed')
        raise ActiveRecord::Rollback
      end
      expect(new_rows.pluck(:id)).to eq([row.id])
    end

    it '検証違反は例外になり、検証を外しても CHECK 制約が拒否する' do
      [{ actor_kind: 'robot' }, { actor_id: '' }, { actor_id: 'a' * 129 }, { actor_id: 'ops lead' }, { actor_id: "ops\nlead" },
       { action: 'Rake.plan' }, { action: "a#{'b' * 128}" }, { target_type: 'Account' }, { target_id: 1 },
       { target_type: 'Toybaco::Support Report', target_id: 1 }, { params_digest: 'ABC' }, { result: 'done' },
       { source: 's' * 129 }, { source: '' }, { source: 'owner@example.invalid' }].each do |change|
        expect { Toybaco::OperatorAction.create!(valid.merge(change)) }.to raise_error(ActiveRecord::RecordInvalid)
        expect { Toybaco::OperatorAction.new(valid.merge(change)).save!(validate: false) }
          .to raise_error(ActiveRecord::StatementInvalid, /tb_operator_/)
      end
      expect { described_class.record!(**context, actor_kind: 'robot', result: 'ok') }.to raise_error(ActiveRecord::RecordInvalid)
      expect(new_rows).to be_empty
    end
  end

  describe '.around' do
    it '前に started、成功で ok を書き、ブロックの値を返す' do
      expect(described_class.around(**context, params: { 'limit' => '5' }) { :done }).to eq(:done)
      expect(new_rows.pluck(:result)).to eq(%w[started ok])
      expect(new_rows.pluck(:actor_kind, :actor_id, :action, :source).uniq).to eq([%w[rake ops-lead rake.toybaco:plan_status ops-rake-1-1]])
      expect(new_rows.pluck(:params_digest).uniq).to eq([described_class.params_digest({ 'limit' => '5' })])
    end

    it '例外では failed を書いてから再送出する' do
      expect { described_class.around(**context) { raise ArgumentError, 'boom' } }.to raise_error(ArgumentError, 'boom')
      expect(new_rows.pluck(:result)).to eq(%w[started failed])
    end

    it 'rake の abort(失敗の終了)は failed、exit 0 は ok にする' do
      expect { described_class.around(**context) { abort 'stop' } }.to raise_error(SystemExit).and output("stop\n").to_stderr
      expect { described_class.around(**context) { exit 0 } }.to raise_error(SystemExit) { |error| expect(error).to be_success } # rubocop:disable Rails/Exit
      expect(new_rows.pluck(:result)).to eq(%w[started failed started ok])
    end

    it '呼び出し元のトランザクションがロールバックしても started と ok / failed は残る' do
      expect do
        ActiveRecord::Base.transaction { described_class.around(**context) { raise 'boom' } }
      end.to raise_error(RuntimeError, 'boom')
      ActiveRecord::Base.transaction do
        described_class.around(**context) { :done }
        raise ActiveRecord::Rollback
      end
      expect(new_rows.pluck(:result)).to eq(%w[started failed started ok])
    end

    it '開始の行を書けなければブロックを実行しない' do
      called = false
      expect { described_class.around(**context, actor_id: '') { called = true } }.to raise_error(ActiveRecord::RecordInvalid)
      expect(called).to be(false)
      expect(new_rows).to be_empty
    end
  end

  describe 'readonly' do
    it '保存済みの行は更新も削除もできない' do
      row = described_class.record!(**context, result: 'ok')
      expect(row).to be_readonly
      expect { row.update!(result: 'failed') }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { row.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect(Toybaco::OperatorAction.find(row.id).result).to eq('ok')
    end
  end

  describe 'DB の追記専用トリガ' do
    it '保持期間内の行は row.delete・update_all・直接の DELETE・TRUNCATE で変えられず、7 年を過ぎた行だけ削除できる' do
      row = described_class.record!(**context, result: 'ok')
      aged = Toybaco::OperatorAction.create!(valid.merge(created_at: 8.years.ago))
      # readonly? を通らない経路を DB のトリガが止めることを確かめる(失敗した文は savepoint ごと巻き戻す)。
      [-> { row.delete },
       -> { Toybaco::OperatorAction.where(id: row.id).update_all(result: 'failed') }, # rubocop:disable Rails/SkipsModelValidations
       -> { ActiveRecord::Base.connection.execute("DELETE FROM toybaco_operator_actions WHERE id = #{row.id}") },
       -> { ActiveRecord::Base.connection.execute('TRUNCATE toybaco_operator_actions') }].each do |statement|
        expect { ActiveRecord::Base.transaction(requires_new: true) { statement.call } }
          .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      end
      expect(Toybaco::OperatorAction.find(row.id).result).to eq('ok')
      expect(Toybaco::OperatorAction.where(id: aged.id).delete_all).to eq(1)
    end
  end

  describe '.web_source' do
    it 'Rails が振る UUID の request_id だけを返し、利用者が渡せるほかの値は使わない' do
      request = ->(id) { instance_double(ActionDispatch::Request, request_id: id) }
      expect(described_class.web_source(request.call('0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0'))).to eq('0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0')
      expect(described_class.web_source(request.call('0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0'))).to eq('0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0')
      expect(described_class.web_source(request.call('owner@example.invalid'))).to be_nil
      expect(described_class.web_source(request.call('a' * 200))).to be_nil
      expect(described_class.web_source(request.call("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0\nx"))).to be_nil
      expect(described_class.web_source(request.call(nil))).to be_nil
    end
  end

  describe '別セッションの後始末' do
    let(:connection) { instance_double(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter, quote: "'x'") }

    before do
      config = instance_double(ActiveRecord::DatabaseConfigurations::HashConfig, new_connection: connection)
      allow(Toybaco::OperatorAction).to receive(:connection_db_config).and_return(config)
      allow(connection).to receive(:disconnect!).and_raise(ActiveRecord::ConnectionNotEstablished, 'disconnect failed')
    end

    it '切断の失敗は握り、INSERT の失敗だけを外へ出す' do
      allow(connection).to receive(:execute).and_return(nil)
      expect { described_class.record_isolated!(**context, result: 'ok') }.not_to raise_error
      allow(connection).to receive(:execute).and_raise(ActiveRecord::StatementInvalid, 'insert failed')
      expect { described_class.record_isolated!(**context, result: 'ok') }.to raise_error(ActiveRecord::StatementInvalid, 'insert failed')
    end
  end
end
