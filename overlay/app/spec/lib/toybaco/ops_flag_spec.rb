# frozen_string_literal: true

require 'rails_helper'

# 運営フラグの読み手(Toybaco::Ops::OpsFlag)。GlobalConfig の cache(Redis)を経由せず DB を直接読むことを確かめる。
# ダイジェストの読み手は ops_digest_spec、店舗一覧の画面(controller とナビゲーション)は super_admin_stores_spec で確かめる。
# 使い方サポートの入口(Toybaco::SupportController の 404)・報告の受付・AI 回答の読み手は (b) で、実際の入口と判定を通して確かめる。
# 置き場所は他の overlay spec(spec/lib/toybaco/*_spec.rb)と揃え、rspec manifest の名簿で固定している。
RSpec.describe Toybaco::Ops::OpsFlag do # rubocop:disable RSpec/SpecFilePathFormat
  let(:flags) do
    %w[TOYBACO_OPS_DIGEST_ENABLED TOYBACO_OPS_CONSOLE_ENABLED TOYBACO_SUPPORT_REPORTS_ENABLED TOYBACO_SUPPORT_ENABLED
       TOYBACO_SUPPORT_AI_ENABLED]
  end

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
    flag_row('TOYBACO_SUPPORT_ENABLED', true)
    flag_row('TOYBACO_SUPPORT_AI_ENABLED', 'true')
    expect(flags.map { |key| described_class.enabled?(key) }).to eq([true, false, false, true, false])
    expect(flags.map { |key| described_class.current(key) }).to eq([true, 'true', nil, true, 'true'])
  end

  it '運営フラグ以外のキーは読まずに ArgumentError にする' do
    InstallationConfig.create!(name: 'TOYBACO_GROWTH_NOTICES_ENABLED', value: true, locked: false)
    ['TOYBACO_GROWTH_NOTICES_ENABLED', 'toybaco_ops_digest_enabled', :TOYBACO_OPS_DIGEST_ENABLED, nil].each do |key|
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

  describe '(b) 店舗一覧・利用者からの報告・使い方サポートの読み手', type: :request do
    let(:account) { create(:account) }
    let(:user) { create(:user, :administrator, account: account) }
    # AI 回答は model と同時実行の枠(Redis)を偽物にし、Toybaco::Support::Answer#call の判定だけを本物で通す。
    let(:model) { instance_double(Toybaco::Support::Model, generate: { 'article_id' => 'reply' }) }
    let(:capacity) { instance_double(Toybaco::Support::Capacity) }

    # 報告の受付は担当者(確認済みの SuperAdmin 2 名)が揃っている時だけ開くので、フラグ以外の条件は満たしておく。
    before do
      owners = create_list(:super_admin, 2)
      stub_const('ENV', ENV.to_h.merge('TOYBACO_SUPPORT_OPERATIONS_OWNER_ID' => owners.first.id.to_s,
                                       'TOYBACO_SUPPORT_BILLING_OWNER_ID' => owners.last.id.to_s))
      allow(capacity).to receive(:within).and_yield
    end

    # 読むたびに、全フラグの古い true を cache に置き直してから読む(行を保存すると after_commit が cache を消すため)。
    # 使い方サポートの入口は、無効なら 404、有効ならログインの確認に進む(この spec は cookie を送らないので 401)。
    def readers
      flags.each { |key| stale_cache(key, true) }
      get '/toybaco/support', params: { account_id: account.id }
      { console: Toybaco::Ops::Console.enabled?, reports: Toybaco::Support::Reports.available?,
        support: response.status, reports_intake: reports_intake?, ai_answer: ai_answer? }
    end

    # 報告の受付(Reports#authorize!)。入口と報告のフラグ・担当者・所属が揃えば一覧を返し、欠ければ Forbidden。
    def reports_intake?
      Toybaco::Support::Reports.new(account, user).list
      true
    rescue Toybaco::Support::Reports::Forbidden
      false
    end

    # AI 回答(Answer の ready!)。入口と AI 回答のフラグが揃えば model に問い合わせ、欠ければ Unavailable。
    def ai_answer?
      Toybaco::Support::Answer.new(account, user, model: model, capacity: capacity).call('返信はどこから行いますか')
      true
    rescue Toybaco::Support::Answer::Unavailable
      false
    end

    it 'cache に true があっても DB に行が無いフラグは無効と読み、DB の boolean true の行を置いたフラグから有効になる' do
      expected = { console: false, reports: false, support: 404, reports_intake: false, ai_answer: false }
      expect(readers).to eq(expected)
      { 'TOYBACO_OPS_CONSOLE_ENABLED' => { console: true }, 'TOYBACO_SUPPORT_REPORTS_ENABLED' => { reports: true },
        'TOYBACO_SUPPORT_ENABLED' => { support: 401, reports_intake: true },
        'TOYBACO_SUPPORT_AI_ENABLED' => { ai_answer: true } }.each do |key, change|
        flag_row(key, true)
        expect(readers).to eq(expected.merge!(change))
      end
      expect(model).to have_received(:generate).once
    end

    it 'AI 回答は入口のフラグも DB で読み、AI 回答の行だけでは(入口の古い true が cache にあっても)開かない' do
      flag_row('TOYBACO_SUPPORT_AI_ENABLED', true)
      expect(readers).to include(support: 404, ai_answer: false)
      expect(model).not_to have_received(:generate)
    end
  end
end
