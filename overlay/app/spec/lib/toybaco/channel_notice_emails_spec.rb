# frozen_string_literal: true

require 'rails_helper'

# 受信チャネルの監視が店舗の管理者へ送るメールの出し分け(lib/toybaco/channel_notice_emails.rb)。owner の明示の了承まで既定は off。
# 各経路の off / on は line_token_verify_job_spec・instagram_token_refresh_job_spec・channel_health_spec で見る。
RSpec.describe Toybaco::ChannelNoticeEmails do
  it 'env の名前は TOYBACO_CHANNEL_NOTICE_EMAILS' do
    expect(described_class::ENV_NAME).to eq('TOYBACO_CHANNEL_NOTICE_EMAILS')
  end

  it '`on` の時だけ送る' do
    with_modified_env('TOYBACO_CHANNEL_NOTICE_EMAILS' => 'on') { expect(described_class.enabled?).to be(true) }
  end

  it '未設定・空・on 以外の値(前後の空白・大文字・true・1 を含む)では送らない' do
    values = [nil, '', 'off', 'ON', 'On', ' on', 'on ', "on\n", 'true', '1', 'yes']

    results = values.map { |value| with_modified_env('TOYBACO_CHANNEL_NOTICE_EMAILS' => value) { described_class.enabled? } }
    expect(results).to eq([false] * values.size)
  end
end
