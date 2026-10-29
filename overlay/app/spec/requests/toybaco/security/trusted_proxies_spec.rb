# frozen_string_literal: true

require 'rails_helper'

# 送信元 IP の決め方(CASA、2026-10-28)。本番の経路は 利用者 → Cloudflare → ALB(private) → Rails。
# Cloudflare の範囲を信頼するのは TOYBACO_TRUST_CLOUDFLARE_PROXY=1 の時だけ(前提は origin の認証。既定は信頼しない)。
# 信頼する時は request.remote_ip と Rack::Attack の IP 単位の throttle の鍵を利用者の IP にし、ALB に直接届いた request が
# X-Forwarded-For を偽っても、ALB が右端に足した接続元の IP より左は使わない。Forwarded と CF-Connecting-IP はどちらでも読まない。
RSpec.describe Toybaco::Security::TrustedProxies, type: :request do
  let(:alb) { '10.20.30.40' }
  let(:client_a) { '203.0.113.7' }
  let(:client_b) { '203.0.113.8' }
  let(:edge_v4) { '172.70.80.90' } # Cloudflare 172.64.0.0/13
  let(:edge_v6) { '2606:4700:10::ac43:1b0a' } # Cloudflare 2606:4700::/32
  let(:direct_peer) { '192.0.2.44' }
  # upstream の req/ip throttle(config/initializers/rack_attack.rb、鍵は req.ip)と同じ鍵の作り方で、上限だけ 1 回にしたもの。
  let(:req_ip_throttle) do
    Rack::Attack::Throttle.new('toybaco-spec/req-ip', { limit: 1, period: 60 }, &Rack::Attack.configuration.throttles.fetch('req/ip').block)
  end

  # throttle の規則は変えず、数える store だけ使い捨ての memory にする。
  before do
    cache = Rack::Attack::Cache.new
    cache.store = ActiveSupport::Cache::MemoryStore.new
    allow(Rack::Attack).to receive(:cache).and_return(cache)
  end

  # 本番と同じ ActionDispatch::RemoteIp を、Cloudflare を信頼するかどうかを指定して組み、ALB からの request を通した env。
  def env_through_proxies(forwarded_for, trust_cloudflare:, extra: {}, remote_addr: alb)
    captured = nil
    inner = lambda do |env|
      captured = env
      [200, {}, []]
    end
    headers = extra.merge('REMOTE_ADDR' => remote_addr)
    headers['HTTP_X_FORWARDED_FOR'] = forwarded_for if forwarded_for
    ActionDispatch::RemoteIp.new(inner, true, described_class.rails_proxies(trust_cloudflare: trust_cloudflare))
                            .call(Rack::MockRequest.env_for('/', headers))
    captured
  end

  def with_rack_filter(trust_cloudflare:)
    original = Rack::Request.ip_filter
    Rack::Request.ip_filter = described_class.rack_ip_filter(trust_cloudflare: trust_cloudflare)
    yield
  ensure
    Rack::Request.ip_filter = original
  end

  # [request.remote_ip, Rack::Attack の鍵(Rack の request.ip)]
  def resolved(forwarded_for, trust_cloudflare:, extra: {})
    env = env_through_proxies(forwarded_for, trust_cloudflare: trust_cloudflare, extra: extra)
    with_rack_filter(trust_cloudflare: trust_cloudflare) { [ActionDispatch::Request.new(env).remote_ip, Rack::Attack::Request.new(env).ip] }
  end

  # 1 つ目の request を数えたあと、2 つ目の request が上限(1 回)を超えて throttle されるか。
  def second_throttled?(first, second, trust_cloudflare:)
    with_rack_filter(trust_cloudflare: trust_cloudflare) do
      [first, second].map do |forwarded_for|
        req_ip_throttle.matched_by?(Rack::Attack::Request.new(env_through_proxies(forwarded_for, trust_cloudflare: trust_cloudflare)))
      end.last
    end
  end

  describe 'TOYBACO_TRUST_CLOUDFLARE_PROXY=1(origin の認証を入れた後)' do
    it 'Cloudflare の IPv4・IPv6 の edge 経由では利用者の IP を remote_ip と Rack::Attack の鍵にする' do
      expect(resolved("#{client_a}, #{edge_v4}", trust_cloudflare: true)).to eq([client_a, client_a])
      expect(resolved("#{client_a}, #{edge_v6}", trust_cloudflare: true)).to eq([client_a, client_a])
      expect(resolved("2001:db8::7, #{edge_v4}", trust_cloudflare: true)).to eq(['2001:db8::7', '2001:db8::7'])
    end

    it '同じ edge の後ろの 2 利用者を Rack::Attack の req/ip throttle が別々に数える' do
      expect(second_throttled?("#{client_a}, #{edge_v4}", "#{client_b}, #{edge_v4}", trust_cloudflare: true)).to be(false)
      expect(second_throttled?("#{client_a}, #{edge_v4}", "#{client_a}, #{edge_v4}", trust_cloudflare: true)).to be(true)
    end

    it 'ALB に直接届いた request は X-Forwarded-For を偽っても鍵を選べず、ALB が足した接続元の IP で数えられる' do
      forged = "#{client_b}, #{edge_v4}, #{direct_peer}"
      expect(resolved(forged, trust_cloudflare: true)).to eq([direct_peer, direct_peer])
      expect(second_throttled?("#{client_a}, #{edge_v4}, #{direct_peer}", forged, trust_cloudflare: true)).to be(true)
    end
  end

  describe '既定(スイッチなし。本番の今の挙動)' do
    it 'Cloudflare の範囲を信頼せず、remote_ip と Rack::Attack の鍵は edge の IP のまま' do
      expect(resolved("#{client_a}, #{edge_v4}", trust_cloudflare: false)).to eq([edge_v4, edge_v4])
      expect(second_throttled?("#{client_a}, #{edge_v4}", "#{client_b}, #{edge_v4}", trust_cloudflare: false)).to be(true)
    end

    it 'スイッチは 1 の時だけ有効で、test の起動(未設定)では Rails の trusted_proxies と Rack の ip_filter を変えない' do
      expect(described_class.trust_cloudflare?({})).to be(false)
      expect(described_class.trust_cloudflare?('TOYBACO_TRUST_CLOUDFLARE_PROXY' => 'true')).to be(false)
      expect(described_class.trust_cloudflare?('TOYBACO_TRUST_CLOUDFLARE_PROXY' => '1')).to be(true)
      expect(Rails.application.config.action_dispatch.trusted_proxies).to be_nil
      expect(Rack::Request.ip_filter).to equal(described_class::RACK_DEFAULT_FILTER)
    end

    it '実際の middleware を通した request でも edge の IP を使い、Forwarded は読まない' do
      get '/health', headers: { 'X-Forwarded-For' => "#{client_a}, #{edge_v4}", 'Forwarded' => 'for=198.51.100.99' },
                     env: { 'REMOTE_ADDR' => alb }
      expect(response).to have_http_status(:ok)
      expect([request.remote_ip, Rack::Attack::Request.new(request.env).ip]).to eq([edge_v4, edge_v4])
    end
  end

  # upstream の safelist 'trusted IPs'(rack_attack.rb の allowed_ip?)は remote_ip が loopback なら全 throttle を飛ばす。
  describe "Rack::Attack の safelist 'trusted IPs' の loopback" do
    let(:trusted_ips) { Rack::Attack.configuration.safelists.fetch('trusted IPs') }

    def safelisted?(forwarded_for, trust_cloudflare:, remote_addr: alb)
      env = env_through_proxies(forwarded_for, trust_cloudflare: trust_cloudflare, remote_addr: remote_addr)
      with_rack_filter(trust_cloudflare: trust_cloudflare) { trusted_ips.matched_by?(Rack::Attack::Request.new(env)) }
    end

    it 'X-Forwarded-For に置いた 127.0.0.1・::1 は、remote_ip になってもスイッチによらず safelist に入らない' do
      expect(resolved("127.0.0.1, #{edge_v4}", trust_cloudflare: true).first).to eq('127.0.0.1')
      expect(safelisted?("127.0.0.1, #{edge_v4}", trust_cloudflare: true)).to be(false)
      expect(safelisted?("::1, #{edge_v6}", trust_cloudflare: true)).to be(false)
      expect(resolved('127.0.0.1, 10.1.2.3', trust_cloudflare: false).first).to eq('127.0.0.1')
      expect(safelisted?('127.0.0.1, 10.1.2.3', trust_cloudflare: false)).to be(false)
    end

    it '直接の接続元が loopback の request は、従来どおり safelist に入る' do
      [true, false].each do |trust|
        expect(safelisted?(nil, trust_cloudflare: trust, remote_addr: '127.0.0.1')).to be(true)
        expect(safelisted?(nil, trust_cloudflare: trust, remote_addr: '::1')).to be(true)
      end
    end

    it 'RACK_ATTACK_ALLOWED_IPS の照合は upstream のまま remote_ip で行う' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('RACK_ATTACK_ALLOWED_IPS', '').and_return(client_a)
      expect(safelisted?("#{client_a}, #{edge_v4}", trust_cloudflare: true)).to be(true)
      expect(safelisted?("#{client_b}, #{edge_v4}", trust_cloudflare: true)).to be(false)
    end
  end

  describe 'スイッチによらない' do
    it 'Forwarded と CF-Connecting-IP は読まず、X-Forwarded-For だけで決める' do
      forged = { 'HTTP_FORWARDED' => 'for=198.51.100.99', 'HTTP_CF_CONNECTING_IP' => '198.51.100.98' }
      [true, false].each do |trust|
        expect(resolved(direct_peer, trust_cloudflare: trust, extra: forged)).to eq([direct_peer, direct_peer])
      end
      expect(Rack::Request.forwarded_priority).to eq([:x_forwarded])
    end

    it 'Cloudflare 以外の公開 IP は信頼せず、private の既定は残す' do
      [true, false].each do |trust|
        expect(resolved("#{client_a}, 198.51.100.20", trust_cloudflare: trust)).to eq(%w[198.51.100.20 198.51.100.20])
        expect(resolved("#{client_a}, 10.1.2.3", trust_cloudflare: trust)).to eq([client_a, client_a])
      end
    end

    it 'install! は スイッチが 1 の時だけ Rails と Rack に Cloudflare の公開範囲 22 件を足す' do
      original = Rack::Request.ip_filter
      config = ActiveSupport::OrderedOptions.new
      config.action_dispatch = ActiveSupport::OrderedOptions.new
      described_class.install!(config, {})
      expect([config.action_dispatch.trusted_proxies, Rack::Request.ip_filter]).to eq([nil, original])
      described_class.install!(config, 'TOYBACO_TRUST_CLOUDFLARE_PROXY' => '1')
      expect(config.action_dispatch.trusted_proxies).to eq(ActionDispatch::RemoteIp::TRUSTED_PROXIES + described_class::CLOUDFLARE_RANGES)
      expect(Rack::Request.ip_filter).to equal(described_class::CLOUDFLARE_FILTER)
      expect(described_class::CLOUDFLARE_RANGES.size).to eq(22)
    ensure
      Rack::Request.ip_filter = original
    end
  end
end
