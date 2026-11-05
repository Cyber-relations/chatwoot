# frozen_string_literal: true

require 'rails_helper'

# staging の DAST(2026-11-03)で GET audit_logs が NoMethodError(Account の associated_audits)の 500 になった。staging・本番は
# DISABLE_ENTERPRISE で、Account に enterprise の has_associated_audits(Enterprise::Audit::Account)が付かない。gate の RSpec は
# enterprise を読むので、その build の Account を「associated_audits が定義されていない(呼ぶと NoMethodError)」形で再現する。
# 機能が無い build では 404、ある build では今のまま。照らすのは認証・管理者の確認の後。
RSpec.describe 'Toybaco audit logs availability', type: :request do
  let!(:account) { create(:account) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let(:path) { "/api/v1/accounts/#{account.id}/audit_logs" }

  def without_associated_audits
    allow(Account).to receive(:method_defined?).and_call_original
    allow(Account).to receive(:method_defined?).with(:associated_audits).and_return(false)
    allow_any_instance_of(Account).to receive(:associated_audits) do # rubocop:disable RSpec/AnyInstance
      raise NoMethodError, "undefined method 'associated_audits' for an instance of Account"
    end
  end

  it 'associated_audits が無い build では 404 を返す' do
    without_associated_audits
    get path, params: { since: '0', q: 'dast' }, headers: { 'api_access_token' => admin.access_token.token }
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to eq('error' => Toybaco::Security::ApiInputGuard::AuditLogs::MESSAGE)
  end

  it '認証と管理者の確認は今のまま先に効く(匿名は 401、agent は 401)' do
    without_associated_audits
    get path
    expect(response).to have_http_status(:unauthorized)
    agent = create(:user, account: account, role: :agent)
    get path, headers: { 'api_access_token' => agent.access_token.token }
    expect(response).to have_http_status(:unauthorized)
  end

  it 'associated_audits がある build(enterprise)では今の応答を返す' do
    expect(Account.method_defined?(:associated_audits)).to be(true)
    get path, headers: { 'api_access_token' => admin.access_token.token }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('audit_logs' => [], 'current_page' => 1, 'per_page' => 25)
  end
end
