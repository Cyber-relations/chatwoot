# frozen_string_literal: true

require 'rails_helper'

# staging の DAST(2026-11-03)で enum の外の値が ArgumentError('…' is not a valid …)の 500 になった経路。
# Rails の enum の代入と同じ条件で先に照らし、RecordInvalid と同じ形の 422 を返す。行は作らず、値が空・正しい値の時は今のまま。
RSpec.describe 'Toybaco API enum value guard', type: :request do
  let!(:account) { create(:account) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:contact) { create(:contact, account: account) }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, status: :open) }
  let(:headers) { { 'api_access_token' => admin.access_token.token } }
  let(:base) { "/api/v1/accounts/#{account.id}" }

  def enum_error(attribute, mapping)
    { 'message' => "#{attribute} は #{mapping.keys.join('・')} のいずれかを指定してください。", 'attributes' => [attribute] }
  end

  describe 'custom_attribute_definitions' do
    let(:definition) do
      { attribute_display_name: 'DAST 属性', attribute_key: 'dast_key', attribute_model: 'contact_attribute', attribute_display_type: 'text' }
    end

    %w[attribute_model attribute_display_type].each do |attribute|
      it "POST の #{attribute} が enum の外なら 422 を返し、行を作らない" do
        expect do
          post "#{base}/custom_attribute_definitions", params: { custom_attribute_definition: definition.merge(attribute => 'dast') },
                                                       headers: headers, as: :json
        end.not_to change(CustomAttributeDefinition, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq(enum_error(attribute, CustomAttributeDefinition.defined_enums.fetch(attribute)))
      end

      it "PATCH の #{attribute} が enum の外なら 422 を返し、行を変えない" do
        record = account.custom_attribute_definitions.create!(definition)
        patch "#{base}/custom_attribute_definitions/#{record.id}", params: { custom_attribute_definition: { attribute => 'dast' } },
                                                                   headers: headers, as: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq(enum_error(attribute, CustomAttributeDefinition.defined_enums.fetch(attribute)))
        expect(record.reload.attributes.slice('attribute_model', 'attribute_display_type'))
          .to eq('attribute_model' => 'contact_attribute', 'attribute_display_type' => 'text')
      end
    end

    it '正しい値(鍵・数の値)と、値が無い時は今のまま作る' do
      post "#{base}/custom_attribute_definitions", params: { custom_attribute_definition: definition }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.values_at('attribute_model', 'attribute_display_type')).to eq(%w[contact_attribute text])

      post "#{base}/custom_attribute_definitions",
           params: { custom_attribute_definition: definition.merge(attribute_key: 'dast_number', attribute_model: 1, attribute_display_type: 5) },
           headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.values_at('attribute_model', 'attribute_display_type')).to eq(%w[contact_attribute date])

      post "#{base}/custom_attribute_definitions",
           params: { custom_attribute_definition: definition.except(:attribute_model, :attribute_display_type).merge(attribute_key: 'dast_default') },
           headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.values_at('attribute_model', 'attribute_display_type')).to eq(%w[conversation_attribute text])
    end

    it '空の値は今のまま model の検証(RecordInvalid の 422)に任せる' do
      expect do
        post "#{base}/custom_attribute_definitions", params: { custom_attribute_definition: definition.merge(attribute_model: '') },
                                                     headers: headers, as: :json
      end.not_to change(CustomAttributeDefinition, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['attributes']).to include('attribute_model')
      expect(response.parsed_body['message']).not_to include('のいずれかを指定してください')
    end
  end

  describe 'conversations' do
    let(:statuses) { Conversation.defined_enums.fetch('status') }

    it 'POST の status が enum の外なら 422 を返し、会話も連絡先の受信箱も作らない' do
      counts = -> { [Conversation.count, ContactInbox.count] }
      before_counts = counts.call
      post "#{base}/conversations", params: { inbox_id: inbox.id, contact_id: contact.id, status: 'dast' }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq(enum_error('status', statuses))
      expect(counts.call).to eq(before_counts)
    end

    it 'POST の正しい status と、status が無い時は今のまま作る' do
      post "#{base}/conversations", params: { inbox_id: inbox.id, contact_id: contact.id, status: 'pending' }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['status']).to eq('pending')

      post "#{base}/conversations", params: { inbox_id: inbox.id, contact_id: contact.id }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['status']).to eq('open')
    end

    it 'POST の status の検査は認可と受信箱の確認の後(他店舗の受信箱は今のまま 404)' do
      other_inbox = create(:inbox)
      post "#{base}/conversations", params: { inbox_id: other_inbox.id, contact_id: contact.id, status: 'dast' }, headers: headers, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it 'toggle_status の status が enum の外なら 422 を返し、状態を変えない' do
      %w[dast 9].each do |status|
        post "#{base}/conversations/#{conversation.display_id}/toggle_status", params: { status: status }, headers: headers, as: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq(enum_error('status', statuses))
      end
      expect(conversation.reload.status).to eq('open')
    end

    it 'toggle_status の正しい status と、status が無い時の切り替えは今のまま' do
      post "#{base}/conversations/#{conversation.display_id}/toggle_status", params: { status: 'pending' }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['payload'].values_at('success', 'current_status')).to eq([true, 'pending'])

      post "#{base}/conversations/#{conversation.display_id}/toggle_status", headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('payload', 'current_status')).to eq('open')
    end

    it 'toggle_status の検査は会話の確認の後(無い会話は今のまま 404)' do
      post "#{base}/conversations/0/toggle_status", params: { status: 'dast' }, headers: headers, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end
end
