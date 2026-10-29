# frozen_string_literal: true

require 'ipaddr'

# 本番の経路は 利用者 → Cloudflare → AWS ALB → Rails(2026-10-28 に応答の server: cloudflare と cf-ray で確認)。
# Rails と Rack の既定は private の範囲だけを proxy とみなすため、request.remote_ip と Rack::Attack の IP 単位の
# throttle の鍵(Rack の request.ip)は Cloudflare の edge の IP になる。
#
# Cloudflare の公開範囲を proxy として信頼するのは、環境変数 TOYBACO_TRUST_CLOUDFLARE_PROXY=1 の時だけ(既定は信頼
# しない。terraform には置かない)。前提: ALB へ届く request が Toybaco の Cloudflare zone を通ったことを origin 側で
# 認証すること(Authenticated Origin Pulls の zone 専用証明書による mTLS、または Cloudflare の rule が付ける秘密の
# header を信頼の前に照合する)。認証が無いまま信頼すると、他人の Cloudflare zone や Worker から ALB(security group
# は 0.0.0.0/0)へ送った request も Cloudflare の範囲から届くので、X-Forwarded-For の左側を偽って remote_ip と
# throttle の鍵を選べる(全段が信頼する範囲だと Rails は左端を返すので 127.0.0.1 を置けば Rack::Attack の safelist
# にも入る)。信頼する時は、X-Forwarded-For の右から信頼する範囲の IP だけを飛ばす(private の既定は残す)。
#
# スイッチと関係なく、RFC 7239 の Forwarded は読まない。Rack 3 の既定は Forwarded を X-Forwarded-For より先に読み、
# Rack::Attack の鍵を利用者が `Forwarded: for=` で選べた。CF-Connecting-IP も直接の request が自由に付けられるので読まない。
# 同じくスイッチと関係なく、upstream の Rack::Attack の safelist 'trusted IPs' の loopback(127.0.0.1・::1)は、直接の
# 接続元(REMOTE_ADDR)が loopback の時だけ認める(LoopbackPeer)。
module Toybaco::Security::TrustedProxies
  SWITCH = 'TOYBACO_TRUST_CLOUDFLARE_PROXY'

  # Cloudflare の公開範囲。https://www.cloudflare.com/ips-v4/ と https://www.cloudflare.com/ips-v6/ を 2026-10-28 に取得
  # (同じ内容を https://api.cloudflare.com/client/v4/ips でも確認、etag 38f79d050aa027e3be3865e495dcc9bc)。
  # Cloudflare が範囲を変えたら、この一覧を取り直す。
  CLOUDFLARE_RANGES = %w[
    173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20
    188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
    2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32
  ].map { |range| IPAddr.new(range) }.freeze

  RACK_DEFAULT_FILTER = Rack::Request.ip_filter
  CLOUDFLARE_FILTER = ->(ip) { RACK_DEFAULT_FILTER.call(ip) || cloudflare?(ip) }
  LOOPBACK = %w[127.0.0.1 ::1].freeze

  # upstream の safelist 'trusted IPs'(config/initializers/rack_attack.rb の allowed_ip?)は、remote_ip が 127.0.0.1 か
  # ::1 なら全 throttle を飛ばす。remote_ip は X-Forwarded-For から決まり、全段が信頼する範囲の chain では左端の値になる
  # (スイッチ ON の「127.0.0.1, Cloudflare, Cloudflare」、OFF でも VPC 内からの「127.0.0.1, private」)。loopback は
  # 直接の接続元が loopback の時だけ認める。RACK_ATTACK_ALLOWED_IPS の照合は upstream のまま。
  module LoopbackPeer
    def allowed_ip?
      return LOOPBACK.include?(get_header('REMOTE_ADDR').to_s.strip) if LOOPBACK.include?(remote_ip)

      super
    end
  end

  module_function

  def install!(config, env = ENV)
    Rack::Request.forwarded_priority = [:x_forwarded]
    Rack::Attack::Request.prepend(LoopbackPeer) unless Rack::Attack::Request < LoopbackPeer
    return unless trust_cloudflare?(env)

    config.action_dispatch.trusted_proxies = rails_proxies(trust_cloudflare: true)
    Rack::Request.ip_filter = rack_ip_filter(trust_cloudflare: true)
  end

  def trust_cloudflare?(env = ENV)
    env[SWITCH] == '1'
  end

  def rails_proxies(trust_cloudflare:)
    return ActionDispatch::RemoteIp::TRUSTED_PROXIES unless trust_cloudflare

    ActionDispatch::RemoteIp::TRUSTED_PROXIES + CLOUDFLARE_RANGES
  end

  def rack_ip_filter(trust_cloudflare:)
    trust_cloudflare ? CLOUDFLARE_FILTER : RACK_DEFAULT_FILTER
  end

  def cloudflare?(ip)
    address = IPAddr.new(ip.to_s)
    CLOUDFLARE_RANGES.any? { |range| range.include?(address) }
  rescue IPAddr::Error
    false
  end
end
