# frozen_string_literal: true

require 'rails_helper'

# 運営フラグの読み手(Toybaco::Ops::OpsFlag)。GlobalConfig の cache(Redis)を経由せず DB を直接読むことを確かめる。
# ダイジェストの読み手は ops_digest_spec、店舗一覧の画面(controller とナビゲーション)は super_admin_stores_spec で確かめる。
# 置き場所は他の overlay spec(spec/lib/toybaco/*_spec.rb)と揃え、rspec manifest の名簿で固定している。
RSpec.describe Toybaco::Ops::OpsFlag do # rubocop:disable RSpec/SpecFilePathFormat
  let(:flags) { %w[TOYBACO_OPS_DIGEST_ENABLED TOYBACO_OPS_CONSOLE_ENABLED TOYBACO_SUPPORT_REPORTS_ENABLED] }

  # 例の中で Redis に置いた古い値を後続の例へ残さない。
  after { GlobalConfig.clear_cache }

  # upstream の GlobalConfig.load_from_cache と同じ key と形で、書き込みと競合した reader が戻す古い値を cache に置く。
  def stale_cache(key, value)
    Redis::Alfred.set("#{GlobalConfig::VERSION}:#{GlobalConfig::KEY_PREFIX}:#{key}", { value: value }.to_json)
  end

  def flag_row(key, value)
    InstallationConfig.create!(name: key, value: value, locked: true)
  end

  it 'enabled? は JSON の boolean true の行だけを有効にし、current は DB の生値(行が無ければ nil)を返す' do
    flag_row('TOYBACO_OPS_DIGEST_ENABLED', true)
    flag_row('TOYBACO_OPS_CONSOLE_ENABLED', 'true')
    expect(flags.map { |key| described_class.enabled?(key) }).to eq([true, false, false])
    expect(flags.map { |key| described_class.current(key) }).to eq([true, 'true', nil])
  end

  it '運営フラグ以外のキーは読まずに ArgumentError にする' do
    InstallationConfig.create!(name: 'TOYBACO_SUPPORT_ENABLED', value: true, locked: false)
    ['TOYBACO_SUPPORT_ENABLED', 'toybaco_ops_digest_enabled', :TOYBACO_OPS_DIGEST_ENABLED, nil].each do |key|
      expect { described_class.enabled?(key) }.to raise_error(ArgumentError)
      expect { described_class.current(key) }.to raise_error(ArgumentError)
    end
  end

  it 'state は boolean・unset・文字列の "true" / "false" を見分け、それ以外は中身も長さも出さず non_boolean にする' do
    values = [true, false, nil, 'true', 'false', 'TRUE', 'x' * 100, '', 1, { 'value' => true }]
    expect(values.map { |value| described_class.state(value) })
      .to eq(['true', 'false', 'unset', '"true"', '"false"'] + (['non_boolean'] * 5))
  end

  it '(a) 保存前の true が cache に残っていても、DB が false なら無効と読む(cache を経由する旧経路は古い true を返す)' do
    flag_row('TOYBACO_OPS_CONSOLE_ENABLED', false)
    stale_cache('TOYBACO_OPS_CONSOLE_ENABLED', true)
    expect(GlobalConfigService.load('TOYBACO_OPS_CONSOLE_ENABLED', false)).to be(true)
    expect(described_class.enabled?('TOYBACO_OPS_CONSOLE_ENABLED')).to be(false)
    expect(described_class.current('TOYBACO_OPS_CONSOLE_ENABLED')).to be(false)
    expect(Toybaco::Ops::Console.enabled?).to be(false)
  end

  describe '(b) 店舗一覧と利用者からの報告の読み手' do
    # 報告の受付は担当者(確認済みの SuperAdmin 2 名)が揃っている時だけ開くので、フラグ以外の条件は満たしておく。
    before do
      owners = create_list(:super_admin, 2)
      stub_const('ENV', ENV.to_h.merge('TOYBACO_SUPPORT_OPERATIONS_OWNER_ID' => owners.first.id.to_s,
                                       'TOYBACO_SUPPORT_BILLING_OWNER_ID' => owners.last.id.to_s))
    end

    def readers
      [Toybaco::Ops::Console.enabled?, Toybaco::Support::Reports.available?]
    end

    it 'cache に true があっても DB に行が無ければ無効で、DB の boolean true で有効になる' do
      flags.each { |key| stale_cache(key, true) }
      expect(readers).to eq([false, false])
      flag_row('TOYBACO_OPS_CONSOLE_ENABLED', true)
      flag_row('TOYBACO_SUPPORT_REPORTS_ENABLED', true)
      expect(readers).to eq([true, true])
    end
  end
end
