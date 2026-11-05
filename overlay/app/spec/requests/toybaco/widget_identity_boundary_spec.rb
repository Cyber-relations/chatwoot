# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget visitor identity boundaries', type: :request do
  let(:widget) { create(:channel_widget) }
  let(:account) { widget.inbox.account }
  let(:customer) do
    create(:contact, account: account, email: 'customer@example.test', identifier: 'customer-id',
                     toybaco_widget_verified_identifier: 'customer-id',
                     name: 'Original customer', phone_number: '+12025550123', custom_attributes: { 'tier' => 'original' })
  end
  let(:customer_fields) { customer.attributes.slice('name', 'email', 'phone_number', 'identifier', 'custom_attributes') }

  let(:origin_headers) { { 'Origin' => 'https://chatwoot.test', 'Sec-Fetch-Site' => 'same-origin', 'X-Toybaco-Widget' => '1' } }
  let(:http_session) do
    post '/api/v1/widget/http_session', params: { website_token: widget.website_token, consume_intent: SecureRandom.hex(32) },
                                        headers: origin_headers, as: :json
    { proof: response.parsed_body.fetch('proof'), record: Toybaco::WidgetSessionRecord.last }
  end
  let(:headers) { origin_headers.merge('X-Auth-Token' => http_session.fetch(:proof)) }

  def visitor_link
    http_session.fetch(:record).reload.contact_inbox
  end

  before do
    host! 'chatwoot.test'
    https!
    http_session
  end

  def identify(fields, endpoint: 'contact/set_user')
    patch "/api/v1/widget/#{endpoint}", params: fields.merge(website_token: widget.website_token), headers: headers, as: :json
  end

  def own_conversation(link = visitor_link)
    create(:conversation, account: account, inbox: widget.inbox, contact_inbox: link, contact: link.contact)
  end

  %i[email phone_number identifier].each do |field|
    it "does not merge or overwrite an existing customer selected by unverified #{field}" do
      original = customer_fields
      fields = { name: 'Visitor name', phone_number: '+12025550129', custom_attributes: { tier: 'visitor' } }
      identify(fields.merge(field => customer.public_send(field)))
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['id']).to eq(visitor_link.contact_id)
      expect(customer.reload.attributes.slice(*original.keys)).to eq(original)
      expect(visitor_link.reload.contact_id).not_to eq(customer.id)
      expect(visitor_link.contact.reload.name).to eq('Visitor name')
      expect(visitor_link.contact.custom_attributes['tier']).to eq('visitor')
    end
  end

  it 'updates unclaimed profile fields without registering an unsigned identifier' do
    identify({ identifier: 'new-visitor', email: 'visitor@example.test', phone_number: '+12025550124', name: 'Visitor' })
    expect(response).to have_http_status(:ok)
    expect(visitor_link.reload.contact.attributes.slice('identifier', 'email', 'phone_number', 'name')).to eq(
      'identifier' => nil, 'email' => 'visitor@example.test', 'phone_number' => '+12025550124', 'name' => 'Visitor'
    )
  end

  it 'does not merge prechat contact updates even in an HMAC mandatory inbox' do
    widget.update!(hmac_mandatory: true)
    original = customer_fields
    identify({ email: customer.email.upcase, phone_number: customer.phone_number, name: 'Visitor', custom_attributes: { tier: 'visitor' } },
             endpoint: 'contact')
    expect(response).to have_http_status(:ok)
    expect(customer.reload.attributes.slice(*original.keys)).to eq(original)
    expect(visitor_link.reload.contact_id).not_to eq(customer.id)
    expect(visitor_link.contact.reload.name).to eq('Visitor')
  end

  it 'does not treat an earlier verified link as proof for new prechat input' do
    visitor_link.update!(hmac_verified: true)
    original = customer_fields
    identify({ email: customer.email, name: 'Visitor' }, endpoint: 'contact')
    expect(response).to have_http_status(:ok)
    expect(customer.reload.attributes.slice(*original.keys)).to eq(original)
    expect(visitor_link.reload.contact_id).not_to eq(customer.id)
  end

  it 'retains upstream merging and field updates for a valid HMAC identify' do
    signature = OpenSSL::HMAC.hexdigest('sha256', widget.hmac_token, customer.identifier)
    identify({ identifier: customer.identifier, identifier_hash: signature, name: 'Verified update', custom_attributes: { tier: 'verified' } })
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['id']).to eq(customer.id)
    expect(visitor_link.reload.contact_id).to eq(customer.id)
    expect(visitor_link).to be_hmac_verified
    expect(customer.reload.name).to eq('Verified update')
    expect(customer.custom_attributes['tier']).to eq('verified')
    expect(response.parsed_body['widget_auth_token']).to start_with('tbwp1.')
  end

  it 'preserves verified identify through the contact update endpoint' do
    signature = OpenSSL::HMAC.hexdigest('sha256', widget.hmac_token, customer.identifier)
    identify({ identifier: customer.identifier, identifier_hash: signature, name: 'Verified update' }, endpoint: 'contact')
    expect(response).to have_http_status(:ok)
    expect(visitor_link.reload.contact_id).to eq(customer.id)
    expect(customer.reload.name).to eq('Verified update')
  end

  it 'updates unclaimed email and phone on the contact selected by its signed identifier' do
    signature = OpenSSL::HMAC.hexdigest('sha256', widget.hmac_token, customer.identifier)
    identify({ identifier: customer.identifier, identifier_hash: signature,
               email: 'new-customer@example.test', phone_number: '+12025550128' })
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['id']).to eq(customer.id)
    expect(customer.reload.email).to eq('new-customer@example.test')
    expect(customer.phone_number).to eq('+12025550128')
  end

  collision_fields = %i[email phone_number]
  existing_identifier_cases = [false, true]
  %w[contact/set_user contact].each do |endpoint|
    collision_fields.each do |field|
      existing_identifier_cases.each do |existing_identifier|
        it "drops unsigned #{field} collisions with an unidentified victim via #{endpoint} " \
           "(existing signed identity: #{existing_identifier})", :aggregate_failures do
          customer.update!(identifier: nil)
          original = customer_fields
          victim_link = create(:contact_inbox, inbox: widget.inbox, contact: customer)
          victim_conversation = own_conversation(victim_link)
          create(:message, account: account, inbox: widget.inbox, conversation: victim_conversation, content: 'Victim private history')
          if existing_identifier
            attacker = create(:contact, account: account, identifier: 'signed-attacker', email: 'attacker@example.test',
                                        toybaco_widget_verified_identifier: 'signed-attacker',
                                        phone_number: '+12025550129')
          end
          signature = OpenSSL::HMAC.hexdigest('sha256', widget.hmac_token, 'signed-attacker')
          collision = field == :email ? customer.email.upcase : customer.phone_number

          identify({ :identifier => 'signed-attacker', :identifier_hash => signature, field => collision,
                     :name => 'Attacker update', :custom_attributes => { tier: 'attacker' } }, endpoint: endpoint)

          expect(response).to have_http_status(:ok)
          selected = visitor_link.reload.contact
          expect(response.parsed_body['id']).to eq(selected.id)
          expect(selected.id).to eq(attacker.id) if existing_identifier
          expect(selected.id).not_to eq(customer.id)
          expect(selected.identifier).to eq('signed-attacker')
          expect(selected.name).to eq('Attacker update')
          expect(selected.custom_attributes['tier']).to eq('attacker')
          expect(selected.public_send(field)).not_to eq(customer.public_send(field))
          expect(selected.public_send(field)).to eq(attacker.public_send(field)) if existing_identifier
          expect(customer.reload.attributes.slice(*original.keys)).to eq(original)
          expect(victim_link.reload.contact_id).to eq(customer.id)
          expect(victim_conversation.reload.contact_id).to eq(customer.id)
          expect(victim_conversation.contact_inbox_id).to eq(victim_link.id)
          proof = response.parsed_body.fetch('widget_auth_token')
          get '/api/v1/widget/messages', params: { website_token: widget.website_token }, headers: origin_headers.merge('X-Auth-Token' => proof)
          expect(response).to have_http_status(:ok)
          expect(response.parsed_body['payload']).to be_empty
        end
      end
    end
  end

  it 'rejects an invalid HMAC before identity or attributes change' do
    original = customer_fields
    identify({ identifier: customer.identifier, identifier_hash: '0' * 64, name: 'Invalid update' })
    expect(response).to have_http_status(:unauthorized)
    expect(customer.reload.attributes.slice(*original.keys)).to eq(original)
    expect(visitor_link.reload.contact_id).not_to eq(customer.id)
  end

  it 'keeps conversation prechat fields on the visitor contact' do
    original = customer_fields
    post '/api/v1/widget/conversations', params: { website_token: widget.website_token,
                                                   contact: { email: customer.email, name: 'Visitor', custom_attributes: { tier: 'visitor' } },
                                                   message: { content: 'Visitor message', timestamp: Time.current.to_i } },
                                         headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(customer.reload.attributes.slice(*original.keys)).to eq(original)
    expect(visitor_link.reload.contact_id).not_to eq(customer.id)
    expect(visitor_link.conversations.last.contact_id).to eq(visitor_link.contact_id)
  end

  it 'keeps an email prompt answer from merging the visitor into the customer' do
    original = customer_fields
    message = create(:message, account: account, inbox: widget.inbox, conversation: own_conversation, content_type: :input_email)
    patch "/api/v1/widget/messages/#{message.id}", params: { website_token: widget.website_token, contact: { email: customer.email } },
                                                   headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(customer.reload.attributes.slice(*original.keys)).to eq(original)
    expect(visitor_link.reload.contact_id).not_to eq(customer.id)
    expect(message.reload.content_attributes['submitted_email']).to eq(customer.email)
  end

  it 'leaves explicit dashboard contact merges available' do
    ContactMergeAction.new(account: account, base_contact: customer, mergee_contact: visitor_link.contact).perform
    expect(visitor_link.reload.contact_id).to eq(customer.id)
  end

  context 'with Dyte meeting messages' do
    let(:processor) { instance_double(Integrations::Dyte::ProcessorService) }

    def meeting_message(conversation)
      create(:message, account: conversation.account, inbox: conversation.inbox, conversation: conversation,
                       content_type: :integrations, content_attributes: { data: { meeting_id: 'synthetic-meeting' } })
    end

    def join_meeting(message)
      post '/api/v1/widget/integrations/dyte/add_participant_to_meeting',
           params: { website_token: widget.website_token, message_id: message.id }, headers: headers, as: :json
    end

    it 'rejects another visitor in the same inbox before calling Dyte' do
      other = create(:contact_inbox, inbox: widget.inbox, contact: customer)
      message = meeting_message(own_conversation(other))
      expect(Integrations::Dyte::ProcessorService).not_to receive(:new)
      join_meeting(message)
      expect(response).to have_http_status(:not_found)
    end

    it 'allows a meeting in an older conversation belonging to the visitor' do
      conversation = own_conversation
      message = meeting_message(conversation)
      own_conversation
      allow(Integrations::Dyte::ProcessorService).to receive(:new).with(account: account, conversation: conversation).and_return(processor)
      expect(processor).to receive(:add_participant_to_meeting).with('synthetic-meeting', visitor_link.contact, message)
                                                               .and_return({ token: 'synthetic-participant' })
      join_meeting(message)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['token']).to eq('synthetic-participant')
    end

    it 'does not share unverified conversations just because a dashboard merge gave them the same contact' do
      other = create(:contact_inbox, inbox: widget.inbox, contact: visitor_link.contact)
      message = meeting_message(own_conversation(other))
      expect(Integrations::Dyte::ProcessorService).not_to receive(:new)
      join_meeting(message)
      expect(response).to have_http_status(:not_found)
    end

    it 'keeps the verified conversation scope across verified links for the same contact' do
      visitor_link.update!(hmac_verified: true)
      other = create(:contact_inbox, inbox: widget.inbox, contact: visitor_link.contact, hmac_verified: true)
      conversation = own_conversation(other)
      message = meeting_message(conversation)
      allow(Integrations::Dyte::ProcessorService).to receive(:new).with(account: account, conversation: conversation).and_return(processor)
      expect(processor).to receive(:add_participant_to_meeting).with('synthetic-meeting', visitor_link.contact, message).and_return({})
      join_meeting(message)
      expect(response).to have_http_status(:ok)
    end

    it 'rejects a meeting from another inbox' do
      message = meeting_message(create(:conversation))
      expect(Integrations::Dyte::ProcessorService).not_to receive(:new)
      join_meeting(message)
      expect(response).to have_http_status(:not_found)
    end
  end
end
