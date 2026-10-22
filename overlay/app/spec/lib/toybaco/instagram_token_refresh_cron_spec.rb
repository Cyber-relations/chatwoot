# frozen_string_literal: true

require 'rails_helper'

# config/initializers/toybaco_instagram_token_refresh.rb の 4 時間ごとの cron の登録(CW-5)。
# 置き場所は他の overlay の initializer の spec(spec/lib/toybaco/*_spec.rb)と揃え、rspec manifest の名簿で固定している。
RSpec.describe Toybaco::InstagramTokenRefreshJob do # rubocop:disable RSpec/SpecFilePathFormat
  let(:initializer) { Rails.root.join('config/initializers/toybaco_instagram_token_refresh.rb').to_s }
  let(:registered) { [] }
  let(:definition) do
    { name: 'toybaco_instagram_token_refresh', cron: '25 */4 * * * UTC', class: 'Toybaco::InstagramTokenRefreshJob',
      active_job: true, queue: 'scheduled_jobs', source: 'toybaco' }
  end

  before { allow(Sidekiq::Cron::Job).to receive(:create) { |arguments| registered << arguments } }

  it 'Sidekiq server でなければ登録しない' do
    allow(Sidekiq).to receive(:server?).and_return(false)

    load initializer
    expect(registered).to be_empty
  end

  it 'Sidekiq server なら UTC の 4 時間ごと(0・4・8・12・16・20 時 25 分)の cron を scheduled_jobs に 1 件だけ登録する' do
    allow(Sidekiq).to receive(:server?).and_return(true)

    load initializer
    expect(registered).to eq([definition])
    expect(Sidekiq::Cron::Job.new(registered.sole.merge(fetch_missing_args: false))).to be_valid
    # タイムゾーンを明示しているので、ECS の TZ=Asia/Tokyo でも UTC の時刻で動く。
    cron = Fugit.parse_cron(registered.sole[:cron])
    expect([cron.hours, cron.minutes]).to eq([[0, 4, 8, 12, 16, 20], [25]])
    expect(cron.previous_time(Time.utc(2026, 10, 22, 23, 0)).utc).to eq(Time.utc(2026, 10, 22, 20, 25))
    expect(cron.next_time(Time.utc(2026, 10, 22, 23, 0)).utc).to eq(Time.utc(2026, 10, 23, 0, 25))
  end

  it 'name は上流の schedule.yml とほかの initializer の cron と重ならない' do
    names = Rails.root.glob('config/initializers/*.rb').flat_map { |path| path.read.scan(/name: '([a-z_]+)'/).flatten }

    expect(names.tally['toybaco_instagram_token_refresh']).to eq(1)
    expect(YAML.load_file(Rails.root.join('config/schedule.yml')).keys).not_to include('toybaco_instagram_token_refresh')
  end

  # 停止の設定(env TOYBACO_INSTAGRAM_TOKEN_REFRESH=off)。sidekiq-cron はトイバコの create を dynamic として Redis に残すので、
  # image を戻すだけでは cron が消えない。off で起動すると、この cron だけを消す。
  context 'when TOYBACO_INSTAGRAM_TOKEN_REFRESH is off' do
    let(:logged) { StringIO.new }

    before do
      allow(Sidekiq).to receive(:server?).and_return(true)
      allow(Sidekiq::Cron::Job).to receive(:destroy).and_return(true)
      allow(Rails).to receive(:logger).and_return(Logger.new(logged))
    end

    it '登録せず、この cron だけを destroy して、固定の行を出す' do
      with_modified_env('TOYBACO_INSTAGRAM_TOKEN_REFRESH' => 'off') { load initializer }

      expect(registered).to be_empty
      expect(Sidekiq::Cron::Job).to have_received(:destroy).with('toybaco_instagram_token_refresh').once
      expect(logged.string).to include('TOYBACO_INSTAGRAM_TOKEN_CRON=removed')
    end

    it 'Sidekiq server でなければ(web の process)、off でも何もしない' do
      allow(Sidekiq).to receive(:server?).and_return(false)

      with_modified_env('TOYBACO_INSTAGRAM_TOKEN_REFRESH' => 'off') { load initializer }
      expect(registered).to be_empty
      expect(Sidekiq::Cron::Job).not_to have_received(:destroy)
    end

    it 'off 以外の値(on)では今のまま登録し、destroy しない' do
      with_modified_env('TOYBACO_INSTAGRAM_TOKEN_REFRESH' => 'on') { load initializer }

      expect(registered).to eq([definition])
      expect(Sidekiq::Cron::Job).not_to have_received(:destroy)
    end
  end

  context 'with the real sidekiq-cron (Redis)' do
    let(:other) { 'toybaco_spec_other_cron' }

    before do
      allow(Sidekiq::Cron::Job).to receive(:create).and_call_original
      allow(Sidekiq).to receive(:server?).and_return(true)
      [definition[:name], other].each { |name| Sidekiq::Cron::Job.destroy(name) }
    end

    after { [definition[:name], other].each { |name| Sidekiq::Cron::Job.destroy(name) } }

    it 'off で起動すると、登録済みのこの cron だけが消え、ほかの cron は残る。off 以外に戻すと 4 時間ごとで登録し直す' do
      load initializer
      Sidekiq::Cron::Job.create(name: other, cron: '0 3 * * * UTC', class: 'Toybaco::InstagramTokenRefreshJob', queue: 'scheduled_jobs')
      expect(Sidekiq::Cron::Job.find(definition[:name])).to be_present

      with_modified_env('TOYBACO_INSTAGRAM_TOKEN_REFRESH' => 'off') { 2.times { load initializer } }
      expect(Sidekiq::Cron::Job.find(definition[:name])).to be_nil
      expect(Sidekiq::Cron::Job.find(other)&.cron).to eq('0 3 * * * UTC')

      with_modified_env('TOYBACO_INSTAGRAM_TOKEN_REFRESH' => 'on') { load initializer }
      expect(Sidekiq::Cron::Job.find(definition[:name])&.cron).to eq('25 */4 * * * UTC')
    end
  end
end
