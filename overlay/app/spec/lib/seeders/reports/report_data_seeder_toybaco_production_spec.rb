# frozen_string_literal: true

require 'rails_helper'

Rails.application.load_tasks unless Rake::Task.task_defined?('db:seed:reports_data')

# CASA 1.2.1: 上流の rake db:seed:reports_data は ENABLE_ACCOUNT_SEEDING を自分で 'true' にしてから seeder を作るので
# (lib/tasks/seed_reports_data.rake:11)、seeder の production の guard(report_data_seeder.rb:54)が効かず、固定の
# パスワードの担当者(:139)を作れる。本番では環境変数に関わらず、店舗のデータを消す・作る前に止める。
RSpec.describe Seeders::Reports::ReportDataSeeder do
  let(:account) { create(:account) }
  let(:refused) { Toybaco::Security::ReportsSeedGuard::Refused }

  it 'refuses in production whatever ENABLE_ACCOUNT_SEEDING says' do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))

    [nil, 'true', 'false'].each do |seeding|
      with_modified_env(ENABLE_ACCOUNT_SEEDING: seeding) do
        expect { described_class.new(account: account) }.to raise_error(refused, /本番では実行できません/)
      end
    end
  end

  it 'stops the production rake task before it creates any agent' do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))
    users = User.count

    expect do
      with_modified_env(ACCOUNT_ID: account.id.to_s, ENABLE_ACCOUNT_SEEDING: nil) do
        expect { Rake::Task['db:seed:reports_data'].execute }.to raise_error(refused)
      end
    end.to output(/Starting reports data seeding/).to_stdout

    expect(User.count).to eq(users)
    expect(account.account_users).to be_empty
  end

  it 'still builds the seeder outside production' do
    with_modified_env(ENABLE_ACCOUNT_SEEDING: nil) do
      expect(described_class.new(account: account)).to be_a(described_class)
    end
  end
end
