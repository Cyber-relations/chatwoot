# frozen_string_literal: true

require 'rails_helper'
require 'base64'

Rails.application.load_tasks unless Rake::Task.task_defined?('toybaco:provision')

# ECS の task(rake)の puts は LogScrub を通らず CloudWatch に生で出る(CASA 6.5.1)。開通と受信箱の行は、契約者のメールアドレス・
# 店舗名・受信箱のアドレスを出さず、行頭・account の番号・plan・subscription・受信箱の local part・受信トレイの名前を残す。
RSpec.describe 'toybaco:provision と受信箱の rake の出力', type: :task do
  let(:email) { "provision-log-#{SecureRandom.hex(4)}@example.invalid" }
  let(:store_name) { "開通ログ確認店#{SecureRandom.hex(4)}" }
  let(:subscription_id) { "sub_provisionlog#{SecureRandom.hex(6)}" }
  let(:client) { instance_double(Toybaco::Checkout::Client) }
  let(:terms) { Toybaco::PlanCatalog.default.definition('pro', '2026-09-06.1') }
  let(:subscription) do
    { 'id' => subscription_id, 'status' => 'active', 'cancel_at_period_end' => false,
      'items' => { 'data' => [{ 'id' => 'si_provisionlog', 'quantity' => 1, 'price' => {
        'id' => 'price_provisionlog', 'currency' => 'jpy', 'unit_amount' => terms.dig('cycles', 'month', 'amount'),
        'recurring' => { 'interval' => 'month', 'interval_count' => 1 },
        'metadata' => { 'toybaco_plan' => 'pro', 'toybaco_plan_version' => terms['plan_version'] }
      } }] } }
  end
  let(:inbox_name) { Toybaco::InboundEmail::INBOX_NAME }

  around do |example|
    with_modified_env(
      MAILER_INBOUND_EMAIL_DOMAIN: 'inbox.staging.toybaco.jp', RAILS_INBOUND_EMAIL_SERVICE: 'ses',
      ACTION_MAILBOX_SES_SNS_TOPIC: 'arn:aws:sns:ap-northeast-1:000000000000:toybaco-inbound-email',
      TOYBACO_INBOUND_EMAIL_MX: nil, TOYBACO_INBOUND_EMAIL_REGION: nil
    ) { example.run }
  end

  before do
    allow(Toybaco::InboundEmail).to receive(:resolve_mx).and_return([Toybaco::InboundEmail::TOKYO_MX])
    allow(Toybaco::Checkout::Client).to receive(:new).and_return(client)
    allow(client).to receive(:retrieve_subscription).with(subscription_id) { Marshal.load(Marshal.dump(subscription)) }
  end

  # rake の puts が書く $stdout の行だけを捕まえる(logger は元の STDOUT を持つ)。
  def stdout_of
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def provision
    payload = { email: email, name: store_name, plan: 'pro', plan_version: terms['plan_version'],
                cycle: 'month', subscription_id: subscription_id }
    Rake::Task['toybaco:provision'].execute(Rake::TaskArguments.new([:payload], [Base64.strict_encode64(payload.to_json)]))
  rescue SystemExit => e
    raise "provision task exited with status #{e.status}"
  end

  def open_inbox(account)
    Rake::Task['toybaco:provision_email_inbox'].execute(Rake::TaskArguments.new([:account_id], [account.id.to_s]))
  rescue SystemExit => e
    raise "provision_email_inbox task exited with status #{e.status}"
  end

  it '新規の開通と再送は account・plan・subscription と受信箱の local part を残し、メールアドレスと店舗名を出さない' do
    first = stdout_of { provision }
    account = Account.find_by!("internal_attributes ->> 'toybaco_subscription_id' = ?", subscription_id)
    again = stdout_of { provision }

    expect(first.lines).to eq(
      ["開通完了: account ##{account.id} / pro / subscription #{subscription_id}\n",
       "メール受信箱作成: account ##{account.id} / shop-#{account.id}\n"]
    )
    expect(again.lines).to eq(
      ["既に開通済み: account ##{account.id}(subscription #{subscription_id})\n",
       "メール受信箱既存: account ##{account.id} / shop-#{account.id}\n"]
    )
    expect(account.name).to eq(store_name)
    expect(first + again).not_to match(Toybaco::Security::LogScrub::EMAIL)
    expect(first + again).not_to include(email.split('@').first)
    expect(first + again).not_to include(store_name)
  end

  it '既存店の受信箱の開通は local part だけを出し、作成・既存と受信トレイの名前を残す' do
    account = create(:account, name: store_name)

    created = stdout_of { open_inbox(account) }
    existing = stdout_of { open_inbox(account) }

    expect(created).to eq("メール受信箱作成: account ##{account.id} / shop-#{account.id} / 受信トレイ「#{inbox_name}」\n")
    expect(existing).to eq("メール受信箱既存: account ##{account.id} / shop-#{account.id} / 受信トレイ「#{inbox_name}」\n")
    expect(created + existing).not_to match(Toybaco::Security::LogScrub::EMAIL)
    expect(created + existing).not_to include(store_name)
  end
end
