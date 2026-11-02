# frozen_string_literal: true

require 'rails_helper'

# PUT /auth/password の再設定 token の期限(Toybaco::Security::PasswordResetExpiry)。確認済みの利用者は reset_password_within
# (6 時間)、未確認の利用者(担当者の招待)は利用開始のリンクの期限 confirm_within(24 時間)。期限切れは未知の token と同じ
# 422(Invalid token)で、確認もパスワードの設定もしない。期限内の token なら、確認の期限が過ぎた未確認の利用者もパスワードの
# 設定と同時に確認し、ログインできる状態にする。token は同時に来た要求でも 1 回だけ使え(lock の中で行を読み直して確かめる)、
# 確認で無料登録の店舗が 1 回だけ有効になる(Growth::FreeConfirmation)。ブラウザー印の無い要求(資格情報はヘッダで返る)で確かめる。
RSpec.describe 'Toybaco password reset expiry', type: :request do
  let(:issued_at) { Time.utc(2026, 10, 20, 3) }
  let(:password) { 'Expiry!2026x' }
  let(:columns) { %w[reset_password_token reset_password_sent_at confirmation_token confirmation_sent_at confirmed_at encrypted_password] }

  def put_password(token, value = password)
    put '/auth/password', params: { reset_password_token: token, password: value, password_confirmation: value }, as: :json
  end

  def issue_token(user, at)
    travel_to(at) { user.send(:set_reset_password_token) }
  end

  def saved_state(user)
    user.reload.attributes.slice(*columns)
  end

  # 担当者の招待と同じ未確認の利用者(確認の通知を止めて保存し、店舗の agent として招待した人を残す)。確認の期限は作成時から数える。
  def invitee
    account = create(:account)
    owner = create(:user, :administrator, account: account)
    travel_to(issued_at) do
      temporary = "1!aA#{SecureRandom.alphanumeric(12)}"
      user = User.new(email: "invite-#{SecureRandom.hex(6)}@example.com", name: '招待 担当者', password: temporary,
                      password_confirmation: temporary)
      user.skip_confirmation_notification!
      user.save!
      AccountUser.create!(account: account, user: user, role: :agent, inviter: owner)
      user
    end
  end

  # 無料登録の正本で、メール確認待ちの店舗(停止中)と未確認の契約者を作る。確認の期限は at から数える。
  def register_owner(at = issued_at)
    attributes = { account_name: 'expiry-store', user_full_name: '期限 確認', email: "expiry-owner-#{SecureRandom.hex(6)}@example.com",
                   password: 'Passw0rd!x2Y' }
    travel_to(at) { Toybaco::Growth::FreeRegistration.new.register!(attributes) }
  end

  def phase(account)
    account.reload.internal_attributes.dig(Toybaco::Growth::FreeRegistration::KEY, 'phase')
  end

  # 確認の commit の後の店舗の有効化(FreeRegistration#activate!)の呼び出しを数える。登録の後に呼ぶ。
  def activation_spy(at)
    Toybaco::Growth::FreeRegistration.new(now: at).tap do |registration|
      allow(Toybaco::Growth::FreeRegistration).to receive(:new).and_return(registration)
      allow(registration).to receive(:activate!).and_call_original
    end
  end

  # 競う要求を演じる: 別の接続で利用者の行を握り、block の要求(この thread の接続)がその lock を待つのを確かめてから、競う要求の
  # 書き込み(save なら握った行への保存で callback を通す、そうでなければ changes の update_all)をして commit する。待ちは、競う側の
  # transaction の外の autocommit の接続から pg_blocking_pids で見る(lock の管理の情報をその時点で読む。pg_stat_activity は transaction
  # の中では最初の読み取りの snapshot を返し続ける)。5 秒の内に見えなければ、書き込まずに失敗する。thread の join は必ず行い、
  # block の例外を thread の例外で隠さない。
  def competing_request(changes, save: false)
    waiter = User.connection.raw_connection.backend_pid
    locked = Queue.new
    id = user.id
    thread = Thread.new { hold_and_write(locked, waiter, id, changes, save) }
    thread.join unless locked.pop
    completed = false
    begin
      yield
      completed = true
    ensure
      completed ? thread.join : join_quietly(thread)
    end
  end

  # 競う要求の thread の本体。行を握ったら locked に知らせ(握る前に終われば false)、待ちを確かめてから書き込む。
  def hold_and_write(locked, waiter, id, changes, save)
    Thread.current.report_on_exception = false
    User.connection_pool.with_connection do |connection|
      User.transaction do
        held = User.lock.find(id)
        locked << true
        wait_for_waiter(connection.raw_connection.backend_pid, waiter)
        save ? held.update!(changes) : User.where(id: id).update_all(changes) # rubocop:disable Rails/SkipsModelValidations
      end
    end
  ensure
    locked << false
  end

  def wait_for_waiter(blocker, waiter)
    observer = ActiveRecord::Base.connection_db_config.new_connection
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until blocked_by?(observer, blocker, waiter)
      timed_out = Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      raise "要求(pid #{waiter})が 5 秒の内に競う要求(pid #{blocker})の行の lock を待たなかったため、書き込まずに止めます" if timed_out

      sleep 0.05
    end
  ensure
    observer&.disconnect!
  end

  def blocked_by?(observer, blocker, waiter)
    observer.select_value(<<~SQL.squish).to_i.positive?
      SELECT CASE WHEN #{Integer(blocker)} = ANY(pg_blocking_pids(#{Integer(waiter)})) THEN 1 ELSE 0 END
    SQL
  end

  def join_quietly(thread)
    thread.join
  rescue StandardError
    nil # block の例外を先に上げるため、thread の失敗は捨てる
  end

  def expect_no_session
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['message']).to eq('Invalid token')
    expect(response.headers['access-token']).to be_nil
    expect(user.reload.tokens).to be_blank
  end

  def expect_rejected(user, token)
    saved = saved_state(user)
    put_password(token)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['message']).to eq('Invalid token')
    expect(response.headers['access-token']).to be_nil
    expect(saved_state(user)).to eq(saved)
  end

  describe '確認済みの利用者(パスワードの再設定)' do
    let(:user) { create(:user) }

    it '発行から 6 時間ちょうどの token では設定できる' do
      token = issue_token(user, issued_at)
      travel_to(issued_at + 6.hours) { put_password(token) }
      expect(response).to have_http_status(:ok)
      expect(user.reload.valid_password?(password)).to be(true)
      expect(user.attributes.values_at('reset_password_token', 'reset_password_sent_at')).to all(be_nil)
    end

    it '6 時間を 1 秒過ぎた token は 422(Invalid token)で、パスワードを変えず token も消さない' do
      token = issue_token(user, issued_at)
      travel_to(issued_at + 6.hours + 1.second) { expect_rejected(user, token) }
      expect(user.reload.valid_password?(password)).to be(false)
      expect(User.with_reset_password_token(token)).to eq(user)
    end
  end

  describe '未確認の利用者(担当者の招待)' do
    it '招待の token は 6 時間を過ぎても 24 時間ちょうどまでは設定でき、確認も済んでログインできる' do
      user = invitee
      token = issue_token(user, issued_at)
      travel_to(issued_at + 24.hours) { put_password(token) }
      expect(response).to have_http_status(:ok)
      expect([user.reload.confirmed?, user.valid_password?(password), user.active_for_authentication?]).to eq([true, true, true])
    end

    it '招待の token が 24 時間を 1 秒過ぎると 422(Invalid token)で、確認もパスワードの設定もしない' do
      user = invitee
      token = issue_token(user, issued_at)
      travel_to(issued_at + 24.hours + 1.second) { expect_rejected(user, token) }
      expect([user.reload.confirmed?, user.valid_password?(password)]).to eq([false, false])
    end

    it '確認の期限を過ぎた招待も、期限内の新しい token ならパスワードの設定と同時に確認し、確認を送った時刻は残す' do
      user = invitee
      sent_at = user.confirmation_sent_at
      token = issue_token(user, issued_at + 25.hours)
      travel_to(issued_at + 25.hours) do
        expect(user.reload.active_for_authentication?).to be(false)
        put_password(token)
      end
      expect(response).to have_http_status(:ok)
      expect(response.headers.values_at('access-token', 'client', 'uid')).to all(be_present)
      expect(user.reload.attributes.values_at('confirmed_at', 'confirmation_sent_at')).to eq([issued_at + 25.hours, sent_at])
      expect([user.valid_password?(password), user.active_for_authentication?]).to eq([true, true])
      expect(user.attributes.values_at('reset_password_token', 'reset_password_sent_at', 'confirmation_token')).to all(be_nil)
    end

    it '確認の期限を過ぎた招待で、パスワードが要件を満たさなければ確認もせず token を残し、設定し直せる' do
      user = invitee
      token = issue_token(user, issued_at + 25.hours)
      travel_to(issued_at + 25.hours) do
        put_password(token, 'Abcdef12')
        expect(response).to have_http_status(:unprocessable_content)
        expect([user.reload.confirmed?, User.with_reset_password_token(token) == user]).to eq([false, true])
        put_password(token)
      end
      expect(response).to have_http_status(:ok)
      expect([user.reload.confirmed?, user.valid_password?(password)]).to eq([true, true])
    end
  end

  describe '無料登録の契約者' do
    # production・staging は CE(DISABLE_ENTERPRISE=true)で監査が無い。test は EE が有効で、確認の commit 後の店舗の有効化
    # (Account#update!)の監査が DeviseController の中で 500 になる(devise_confirmation_browser_spec と同じ理由で監査を止める)。
    around do |example|
      previous = Audited.auditing_enabled
      Audited.auditing_enabled = false
      example.run
    ensure
      Audited.auditing_enabled = previous
    end

    it '確認の期限を過ぎても、再設定の token で確認と同時に店舗が有効になる' do
      attributes = { account_name: 'expiry-store', user_full_name: '期限 確認', email: "expiry-owner-#{SecureRandom.hex(6)}@example.com",
                     password: 'Passw0rd!x2Y' }
      owner, account = travel_to(issued_at) { Toybaco::Growth::FreeRegistration.new.register!(attributes) }
      expect([owner.confirmed?, account.reload.status]).to eq([false, 'suspended'])
      token = issue_token(owner, issued_at + 25.hours)
      travel_to(issued_at + 25.hours) { put_password(token) }
      expect(response).to have_http_status(:ok)
      expect(owner.reload.confirmed?).to be(true)
      expect(account.reload.status).to eq('active')
      expect(account.internal_attributes.dig(Toybaco::Growth::FreeRegistration::KEY, 'phase')).to eq('active')
    end

    # 確認の期限内なら upstream が確認を先に保存し(User#confirm)、パスワードの設定と token の消去を続けて保存する。lock の中の
    # 1 つの transaction で保存が 2〜3 回あり、最後の保存は confirmed_at を変えない。
    it '確認の期限内の契約者が再設定の token を使うと、lock の中の複数の保存でも、確認と同時に店舗が 1 回だけ有効になる' do
      owner, account = register_owner
      token = issue_token(owner, issued_at + 1.hour)
      registration = activation_spy(issued_at + 1.hour)
      travel_to(issued_at + 1.hour) { put_password(token) }
      expect(response).to have_http_status(:ok)
      expect([owner.reload.confirmed_at, owner.valid_password?(password)]).to eq([issued_at + 1.hour, true])
      expect([account.reload.status, phase(account)]).to eq(%w[active active])
      expect(registration).to have_received(:activate!).once
      expect(Toybaco::FreeActivationJob).not_to have_been_enqueued
    end

    it '確認の期限内の契約者のパスワードが要件を満たさなければ、確認もパスワードも戻して店舗を有効にせず token を残し、設定し直せば確認と有効化が起きる' do
      owner, account = register_owner
      token = issue_token(owner, issued_at + 1.hour)
      registration = activation_spy(issued_at + 1.hour)
      travel_to(issued_at + 1.hour) do
        put_password(token, 'Abcdef12')
        expect(response).to have_http_status(:unprocessable_content)
        expect([owner.reload.confirmed?, owner.valid_password?('Abcdef12'), User.with_reset_password_token(token) == owner])
          .to eq([false, false, true])
        expect([account.reload.status, phase(account)]).to eq(%w[suspended email_pending])
        expect(registration).not_to have_received(:activate!)
        put_password(token)
      end
      expect(response).to have_http_status(:ok)
      expect([owner.reload.confirmed?, owner.valid_password?(password), account.reload.status, phase(account)])
        .to eq([true, true, 'active', 'active'])
      expect(registration).to have_received(:activate!).once
    end

    # 店舗の有効化は、確認を保存した transaction の commit の後に走り、その transaction が戻れば捨てられる(Growth::FreeConfirmation)。
    it '外側で確認を保存した後、同じ利用者の内側の savepoint(requires_new)の保存が失敗して戻っても、外側の commit で店舗が 1 回だけ有効になる' do
      owner, account = register_owner
      registration = activation_spy(issued_at + 1.hour)
      travel_to(issued_at + 1.hour) do
        ActiveRecord::Base.transaction do
          expect(owner.confirm).to be(true)
          expect { ActiveRecord::Base.transaction(requires_new: true) { owner.update!(name: nil) } }.to raise_error(ActiveRecord::RecordInvalid)
        end
      end
      expect([owner.reload.confirmed_at, account.reload.status, phase(account)]).to eq([issued_at + 1.hour, 'active', 'active'])
      expect(registration).to have_received(:activate!).once
      expect(Toybaco::FreeActivationJob).not_to have_been_enqueued
    end

    it '確認を内側の savepoint(requires_new)で保存してその savepoint が戻れば、外側が commit しても確認も有効化も残らない' do
      owner, account = register_owner
      registration = activation_spy(issued_at + 1.hour)
      travel_to(issued_at + 1.hour) do
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.transaction(requires_new: true) do
            expect(owner.confirm).to be(true)
            raise ActiveRecord::Rollback
          end
        end
      end
      expect([owner.reload.confirmed?, account.reload.status, phase(account)]).to eq([false, 'suspended', 'email_pending'])
      expect(registration).not_to have_received(:activate!)
    end

    # 内側の release では有効化は走らずに外側へ移り、外側が戻れば捨てられる。後で同じ object を callback なしで確認済みにし、
    # confirmed_at を変えない保存を commit しても有効にしない(release の時に有効化を走らせる版や、確認の状態を持ち越す版では落ちる)。
    it '確認を保存した内側の savepoint を release した後に外側が戻れば有効化も捨てられ、後で confirmed_at を変えない保存を commit しても有効にしない' do
      owner, account = register_owner
      registration = activation_spy(issued_at + 1.hour)
      travel_to(issued_at + 1.hour) do
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.transaction(requires_new: true) { expect(owner.confirm).to be(true) }
          raise ActiveRecord::Rollback
        end
        expect(owner.reload.confirmed?).to be(false)
        owner.update_columns(confirmed_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        owner.update!(display_name: '期限')
      end
      expect([owner.reload.confirmed?, account.reload.status, phase(account)]).to eq([true, 'suspended', 'email_pending'])
      expect(registration).not_to have_received(:activate!)
    end

    # 同じ行を別々に読んだ object が同じ transaction で保存されると、record の commit の callback は最初に保存した object でしか
    # 走らない(load_defaults 7.0)。確認を保存した object がそれでなくても、その transaction の commit で店舗が有効になる。
    it '同じ transaction で同じ利用者の別の object が先に保存されても、確認を保存した transaction の commit で店舗が 1 回だけ有効になり、後の保存で増えない' do
      owner, account = register_owner
      confirming = User.find(owner.id)
      registration = activation_spy(issued_at + 1.hour)
      travel_to(issued_at + 1.hour) do
        ActiveRecord::Base.transaction do
          owner.update!(display_name: '先')
          expect(confirming.confirm).to be(true)
        end
        expect([account.reload.status, phase(account)]).to eq(%w[active active])
        confirming.update!(display_name: '後')
      end
      expect([owner.reload.confirmed?, owner.display_name]).to eq([true, '後'])
      expect(registration).to have_received(:activate!).once
    end

    # 内側の release で有効化は外側の transaction へ移り、外側の commit の後に 1 回だけ走る。
    it '確認を内側の savepoint(requires_new)で保存して release し、外側が commit すれば、店舗が 1 回だけ有効になる' do
      owner, account = register_owner
      registration = activation_spy(issued_at + 1.hour)
      travel_to(issued_at + 1.hour) do
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.transaction(requires_new: true) { expect(owner.confirm).to be(true) }
        end
      end
      expect([owner.reload.confirmed?, account.reload.status, phase(account)]).to eq([true, 'active', 'active'])
      expect(registration).to have_received(:activate!).once
      expect(Toybaco::FreeActivationJob).not_to have_been_enqueued
    end
  end

  # 同じ token の要求が同時に 2 本来ても、パスワードの設定と session は 1 回だけ(競う要求は competing_request で演じる)。
  describe '並行の要求(単回の使用)' do
    # 競う要求は、別の接続で自分の transaction を commit する。
    self.use_transactional_tests = false

    let!(:user) { create(:user) }

    after { User.find_by(id: user.id)&.destroy! }

    it '先の要求がパスワードを設定して token を消していれば、待っていた要求は 422(Invalid token)で、パスワードも session も出さない' do
      token = user.send(:set_reset_password_token)
      winner = 'Winner!2026y'
      competing_request({ encrypted_password: Devise::Encryptor.digest(User, winner), reset_password_token: nil, reset_password_sent_at: nil }) do
        put_password(token)
      end

      expect_no_session
      expect([user.valid_password?(password), user.valid_password?(winner)]).to eq([false, true])
    end

    it '待つ間に新しい申し込みで token が置き換わると、古い token は 422 で session を出さず、パスワードを変えず新しい token を残す' do
      token = user.send(:set_reset_password_token)
      encrypted = user.reload.encrypted_password
      fresh, fresh_digest = Devise.token_generator.generate(User, :reset_password_token)
      competing_request({ reset_password_token: fresh_digest, reset_password_sent_at: Time.current }) { put_password(token) }

      expect_no_session
      expect([user.encrypted_password, user.valid_password?(password)]).to eq([encrypted, false])
      expect(User.with_reset_password_token(fresh)).to eq(user)
    end

    it '競う要求が無ければ 1 回だけ設定でき、session を出し、同じ token の 2 回目は 422(Invalid token)' do
      token = user.send(:set_reset_password_token)
      put_password(token)

      expect(response).to have_http_status(:ok)
      expect(response.headers['access-token']).to be_present
      expect(user.reload.valid_password?(password)).to be(true)
      saved = saved_state(user)
      put_password(token, 'Again!2026y')
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['message']).to eq('Invalid token')
      expect(response.headers['access-token']).to be_nil
      expect(saved_state(user)).to eq(saved)
    end
  end

  # 無料登録の契約者(確認の期限内)に同じ token の要求が同時に 2 本来た時。先の要求が確認とパスワードの設定を書いて commit し、
  # その commit の後に店舗を有効にする。待っていた要求は何も書かず、有効化も足さない。
  describe '並行の要求(無料の契約者)' do
    self.use_transactional_tests = false

    # devise_confirmation_browser_spec と同じ理由で監査を止める(test だけの EE の監査が、確認の後の店舗の有効化で 500 になる)。
    around do |example|
      previous = Audited.auditing_enabled
      Audited.auditing_enabled = false
      example.run
    ensure
      Audited.auditing_enabled = previous
    end

    # transactional fixtures を使わず、店舗の削除は destroy_async の job を積むだけで行が残るので、ops_e2e_growth_spec と同じく
    # 例の前の各表の id の最大値を控え、例の後にそれより後の行を、外部キーの検査を止めた別の DB セッションで全ての表から消す。
    let!(:id_floors) { id_floors_now }
    let!(:registered) { register_owner(Time.current) }
    let(:user) { registered.first }

    after { delete_rows_after(id_floors) }

    def id_floors_now
      connection = ActiveRecord::Base.connection
      connection.tables.select { |table| connection.columns(table).any? { |column| column.name == 'id' && column.type == :integer } }
                .index_with { |table| connection.select_value("SELECT COALESCE(MAX(id), 0) FROM #{connection.quote_table_name(table)}").to_i }
    end

    def delete_rows_after(floors)
      connection = ActiveRecord::Base.connection_db_config.new_connection
      connection.execute('SET session_replication_role = replica')
      floors.each { |table, floor| connection.execute("DELETE FROM #{connection.quote_table_name(table)} WHERE id > #{Integer(floor)}") }
    ensure
      connection&.disconnect!
    end

    it '先の要求が確認とパスワードの設定をして店舗を 1 回だけ有効にし、待っていた要求は 422(Invalid token)で何も書かず有効化も足さない' do
      owner, account = registered
      token = owner.send(:set_reset_password_token)
      registration = activation_spy(Time.current)
      winner = 'Winner!2026y'
      winning = { confirmed_at: Time.current, password: winner, password_confirmation: winner, reset_password_token: nil,
                  reset_password_sent_at: nil, confirmation_token: nil }
      competing_request(winning, save: true) { put_password(token) }

      expect_no_session
      expect([owner.confirmed?, owner.valid_password?(password), owner.valid_password?(winner)]).to eq([true, false, true])
      expect([account.reload.status, phase(account)]).to eq(%w[active active])
      expect(registration).to have_received(:activate!).once
    end
  end
end
