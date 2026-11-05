# frozen_string_literal: true

require 'rails_helper'

# 第 1 回(enum_values_spec)の残り: toggle_status の読めない snoozed_until(Date::Error・範囲外)、conversations の create の
# 配列の inbox_id・contact_id と Hash でない属性・message、Hash でない custom_attribute_definition。上流が例外にする形は
# 422 で、行を作らない。上流が型を変えて受ける形と正しい入力は今のまま。
RSpec.describe 'Toybaco API conversation and definition shape guard', type: :request do
  let!(:account) { create(:account) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:other_inbox) { create(:inbox, account: account) }
  let!(:contact) { create(:contact, account: account, email: 'dast-shape@example.invalid') }
  let!(:other_contact) { create(:contact, account: account, email: 'dast-shape-other@example.invalid') }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, status: :open) }
  let(:headers) { { 'api_access_token' => admin.access_token.token } }
  let(:base) { "/api/v1/accounts/#{account.id}" }
  let(:toggle_path) { "#{base}/conversations/#{conversation.display_id}/toggle_status" }

  def shape_error(attribute, message)
    { 'message' => message, 'attributes' => [attribute] }
  end

  describe 'toggle_status の snoozed_until' do
    it '読めない値・空の文字列・配列・範囲外は 422 で、状態を変えない' do
      ['dast', '', ['1'], '99999999999999'].each do |value|
        post toggle_path, params: { status: 'snoozed', snoozed_until: value }, headers: headers, as: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body)
          .to eq(shape_error('snoozed_until', Toybaco::Security::ApiInputGuard::Conversations::SNOOZE_MESSAGE))
      end
      expect(conversation.reload.status).to eq('open')
    end

    it '正しい snoozed_until、null の snoozed_until、status が無い時(上流は読まない)は今のまま' do
      until_time = 2.days.from_now.to_i
      post toggle_path, params: { status: 'snoozed', snoozed_until: until_time.to_s }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('payload', 'current_status')).to eq('snoozed')
      expect(conversation.reload.snoozed_until.to_i).to eq(until_time)

      post toggle_path, params: { status: 'open', snoozed_until: nil }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('payload', 'current_status')).to eq('open')

      post toggle_path, params: { snoozed_until: 'dast' }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('payload', 'current_status')).to eq('resolved')
    end
  end

  describe 'conversations の create の形' do
    let(:valid) { { inbox_id: inbox.id, contact_id: contact.id } }

    def expect_shape_rejected(name, params)
      counts = [Conversation.count, ContactInbox.count]
      post "#{base}/conversations", params: params, headers: headers, as: :json
      expect([name, params, response.status]).to eq([name, params, 422])
      expect(response.parsed_body).to eq(shape_error(name, "#{name} の形が正しくありません。"))
      expect([Conversation.count, ContactInbox.count]).to eq(counts)
    end

    it '配列の inbox_id・contact_id と、Hash でない属性・message は 422 で、会話も連絡先の受信箱も作らない' do
      { 'inbox_id' => valid.merge(inbox_id: [inbox.id]), 'contact_id' => valid.merge(contact_id: [contact.id]),
        'additional_attributes' => valid.merge(additional_attributes: 'dast'),
        'custom_attributes' => valid.merge(custom_attributes: ['dast']), 'message' => valid.merge(message: 'dast') }.each do |name, params|
        expect_shape_rejected(name, params)
      end
    end

    it '同じ店舗の実在する 2 件の id の配列は、上流の inbox の認可より前に 422 にする' do
      expect_shape_rejected('inbox_id', valid.merge(inbox_id: [inbox.id, other_inbox.id]))
      expect_shape_rejected('contact_id', valid.merge(contact_id: [contact.id, other_contact.id]))
    end

    it '属性の空の配列・空文字・false は 422(上流は nil 以外に permit! を呼ぶ)' do
      %w[additional_attributes custom_attributes].product([[], '', false]).each do |name, value|
        expect_shape_rejected(name, valid.merge(name.to_sym => value))
      end
    end

    it '上流が読まない空の message と、空の配列の inbox_id は今のまま' do
      ['', false, []].each do |value|
        post "#{base}/conversations", params: valid.merge(message: value), headers: headers, as: :json
        expect([value, response.status]).to eq([value, 200])
      end
      post "#{base}/conversations", params: valid.merge(inbox_id: []), headers: headers, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it '正しい形と、上流が受ける形(Hash の inbox_id の 404、配列の source_id)は今のまま' do
      post "#{base}/conversations",
           params: valid.merge(additional_attributes: { 'dast' => 'a' }, custom_attributes: { 'dast' => 'b' }, message: { content: 'DAST 開始' }),
           headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.values_at('additional_attributes', 'custom_attributes'))
        .to eq([{ 'dast' => 'a' }, { 'dast' => 'b' }])

      post "#{base}/conversations", params: valid.merge(inbox_id: { dast: 1 }), headers: headers, as: :json
      expect(response).to have_http_status(:not_found)
      post "#{base}/conversations", params: valid.merge(source_id: ['dast']), headers: headers, as: :json
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'custom_attribute_definitions の形' do
    it 'Hash でない custom_attribute_definition は 422 で、無い時は今の ParameterMissing の 422、Hash でない attribute_values は今のまま' do
      ['dast', ['dast'], false].each do |definition|
        expect do
          post "#{base}/custom_attribute_definitions", params: { custom_attribute_definition: definition }, headers: headers, as: :json
        end.not_to change(CustomAttributeDefinition, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq('error' => 'custom_attribute_definition の形が正しくありません。')
      end

      [{ dast: '1' }, { custom_attribute_definition: '' }].each do |params|
        post "#{base}/custom_attribute_definitions", params: params, headers: headers, as: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']).to include('param is missing')
      end

      post "#{base}/custom_attribute_definitions",
           params: { custom_attribute_definition: { attribute_display_name: 'DAST', attribute_key: 'dast_values', attribute_values: 'dast' } },
           headers: headers, as: :json
      expect(response).to have_http_status(:ok)
    end
  end
end
