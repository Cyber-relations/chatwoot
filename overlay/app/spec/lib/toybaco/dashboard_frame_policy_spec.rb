# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::DashboardFramePolicy do
  let(:frame_src) { "frame-src 'self' https://post.example.test https://hcaptcha.com https://*.hcaptcha.com" }

  def call_policy(path, headers)
    app = ->(_env) { [200, headers, ['ok']] }
    _status, result, = described_class.new(app, postiz_origin: 'https://post.example.test').call('PATH_INFO' => path)
    result
  end

  def directives(policy, name)
    policy.split(';').map(&:strip).select { |directive| directive.split.first == name }
  end

  it '保護 path では上流の緩い frame-src を捨て、子 frame を自身・Postiz・hCaptcha だけに絞る' do
    headers = call_policy('/app/login', { 'Content-Security-Policy' => "default-src 'self'; frame-src https://evil.example" })
    policy = headers.fetch('Content-Security-Policy')

    expect(directives(policy, 'frame-src')).to eq([frame_src])
    expect(directives(policy, 'frame-ancestors')).to eq(["frame-ancestors 'self'"])
    expect(policy).to include("default-src 'self'")
    expect(policy).not_to include('evil.example')
    expect(headers['X-Frame-Options']).to eq('SAMEORIGIN')
  end

  it "上流が frame-ancestors 'none' を付けた画面は 'none' と DENY を保ち、frame-src は同じにする" do
    headers = call_policy('/toybaco/connections/help/request', { 'Content-Security-Policy' => "frame-ancestors 'none'" })
    policy = headers.fetch('Content-Security-Policy')

    expect(directives(policy, 'frame-ancestors')).to eq(["frame-ancestors 'none'"])
    expect(directives(policy, 'frame-src')).to eq([frame_src])
    expect(headers['X-Frame-Options']).to eq('DENY')
  end

  it '保護しない path(顧客サイトに埋め込む widget)の header は変えない' do
    original = { 'Content-Security-Policy' => "default-src 'none'" }
    headers = call_policy('/widget', original)

    expect(headers).to be(original)
    expect(headers).to eq({ 'Content-Security-Policy' => "default-src 'none'" })
  end

  it '無料登録フォームも保護対象で、hCaptcha の子 frame を許可する' do
    headers = call_policy('/toybaco/free/signup', {})
    policy = headers.fetch('Content-Security-Policy')

    expect(directives(policy, 'frame-src')).to eq([frame_src])
    expect(directives(policy, 'frame-ancestors')).to eq(["frame-ancestors 'self'"])
    expect(headers['X-Frame-Options']).to eq('SAMEORIGIN')
  end
end
