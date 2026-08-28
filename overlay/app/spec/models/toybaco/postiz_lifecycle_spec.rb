# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Toybaco Postiz lifecycle', type: :model do
  let!(:account) { create(:account, internal_attributes: { 'postiz' => { 'enabled' => false } }) }
  let!(:user) { create(:user) }
  let!(:account_user) { create(:account_user, account: account, user: user, role: :administrator) }

  before do
    account.update_columns( # rubocop:disable Rails/SkipsModelValidations
      internal_attributes: {
        'postiz' => {
          'enabled' => true,
          'organization_id' => 'ea4c9157-7b2b-5a8f-b72a-8116534829a8'
        }
      }
    )
    account.reload
    allow(Toybaco::PostizSync).to receive(:sync!).and_return(
      organization_id: account.internal_attributes.dig('postiz', 'organization_id'),
      user_id: 'postiz-user',
      role: 'ADMIN'
    )
    allow(Toybaco::PostizSync).to receive(:demote_membership!).and_return(:demoted)
    allow(Toybaco::PostizSync).to receive(:revoke_membership!).and_return(:revoked)
    allow(Toybaco::PostizSync).to receive(:disable_account!).and_return(:disabled)
    allow(Toybaco::PostizSync).to receive(:disable_user!).and_return(:disabled)
  end

  it 'AccountUser createをcommit後に同期する' do
    another_user = create(:user)

    create(:account_user, account: account, user: another_user, role: :agent)

    expect(Toybaco::PostizSync).to have_received(:sync!).with(user: another_user, account: account)
  end

  it '権限付与の同期失敗はdurable jobへ渡し、未同期のまま過剰付与しない' do
    another_user = create(:user)
    allow(Toybaco::PostizSync).to receive(:sync!).and_raise(Toybaco::PostizSync::Unavailable)
    expect(Toybaco::PostizMembershipJob).to receive(:perform_later).with(another_user.id, account.id)

    create(:account_user, account: account, user: another_user, role: :agent)
  end

  it 'administratorからagentへの変更はChatwoot commit前に同期失敗したらrollbackする' do
    allow(Toybaco::PostizSync).to receive(:demote_membership!).and_raise(Toybaco::PostizSync::Unavailable)

    expect { account_user.update!(role: :agent) }.to raise_error(Toybaco::PostizSync::Unavailable)
    expect(account_user.reload).to be_administrator
  end

  it 'agentからadministratorへの昇格はcommit後にPostizへ付与する' do
    account_user.update_columns(role: AccountUser.roles.fetch('agent')) # rubocop:disable Rails/SkipsModelValidations
    account_user.reload

    account_user.update!(role: :administrator)

    expect(Toybaco::PostizSync).to have_received(:sync!).with(user: user, account: account)
  end

  it 'AccountUser destroyはPostiz失効に失敗したらrollbackする' do
    allow(Toybaco::PostizSync).to receive(:revoke_membership!).and_raise(Toybaco::PostizSync::Unavailable)

    expect { account_user.destroy! }.to raise_error(Toybaco::PostizSync::Unavailable)
    expect(account_user.reload).to be_persisted
  end

  it 'Account suspendedは全Postiz所属の失効に失敗したらrollbackする' do
    allow(Toybaco::PostizSync).to receive(:disable_account!).and_raise(Toybaco::PostizSync::Unavailable)

    expect { account.update!(status: :suspended) }.to raise_error(Toybaco::PostizSync::Unavailable)
    expect(account.reload).to be_active
  end

  it '投稿オプション無効化は全Postiz所属の失効に失敗したらrollbackする' do
    allow(Toybaco::PostizSync).to receive(:disable_account!).and_raise(Toybaco::PostizSync::Unavailable)
    attributes = account.internal_attributes.deep_dup
    attributes['postiz']['enabled'] = false

    expect { account.update!(internal_attributes: attributes) }.to raise_error(Toybaco::PostizSync::Unavailable)
    expect(account.reload.internal_attributes.dig('postiz', 'enabled')).to be(true)
  end

  it 'AccountUser destroy成功時は旧session/API失効処理を同期実行してから削除する' do
    account_user.destroy!

    expect(Toybaco::PostizSync).to have_received(:revoke_membership!).with(user_id: user.id, account: account)
    expect(AccountUser.exists?(account_user.id)).to be(false)
  end

  it 'Account destroyは全Postiz所属を同期失効してから削除する' do
    account.destroy!

    expect(Toybaco::PostizSync).to have_received(:disable_account!).with(account: account)
    expect(Account.exists?(account.id)).to be(false)
  end

  it 'User destroyは全Postiz所属と旧sessionを同期失効してから削除する' do
    user.destroy!

    expect(Toybaco::PostizSync).to have_received(:disable_user!).with(user_id: user.id)
    expect(User.exists?(user.id)).to be(false)
  end

  it 'account再有効化はcommit後に全現行memberを同期する' do
    account.update_columns( # rubocop:disable Rails/SkipsModelValidations
      status: Account.statuses.fetch('suspended')
    )
    account.reload

    account.update!(status: :active)

    expect(Toybaco::PostizSync).to have_received(:sync!).with(user: user, account: account)
  end
end
