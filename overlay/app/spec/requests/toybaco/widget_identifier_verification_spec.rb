# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget identifier verification', type: :request do
  numeric_identifier_forms = [123, '123', 123].freeze

  let(:widget) { create(:channel_widget, hmac_mandatory: false) }
  let(:identifier) { 'signed-customer' }
  let(:origin_headers) do
    { 'Origin' => 'https://chatwoot.test', 'Sec-Fetch-Site' => 'same-origin', 'X-Toybaco-Widget' => '1' }
  end
  let(:signed_fields) do
    { identifier: identifier, identifier_hash: OpenSSL::HMAC.hexdigest('sha256', widget.hmac_token, identifier.to_s),
      name: 'Verified customer', email: 'verified@example.test', custom_attributes: { tier: 'verified' } }
  end

  def new_visitor
    client = ActionDispatch::Integration::Session.new(Rails.application)
    client.host! 'chatwoot.test'
    client.https!
    client.post '/api/v1/widget/http_session',
                params: { website_token: widget.website_token, consume_intent: SecureRandom.hex(32) },
                headers: origin_headers, as: :json
    expect(client.response).to have_http_status(:ok)
    { client: client, proof: client.response.parsed_body.fetch('proof'), row: Toybaco::WidgetSessionRecord.last }
  end

  def widget_request(visitor, method, endpoint, fields = {})
    visitor.fetch(:client).public_send(method, "/api/v1/widget/#{endpoint}",
                                       params: fields.merge(website_token: widget.website_token),
                                       headers: origin_headers.merge('X-Auth-Token' => visitor.fetch(:proof)), as: :json)
    response = visitor.fetch(:client).response
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def current_contact(visitor)
    visitor.fetch(:row).reload.contact_inbox.contact
  end

  def signed_identify(visitor, endpoint)
    result = widget_request(visitor, :patch, endpoint, signed_fields)
    visitor[:proof] = result.fetch('widget_auth_token')
    expect(result.fetch('widget_http_identity_changed')).to be(true)
    expect_verified_contact(visitor)
  end

  def expect_verified_contact(visitor)
    contact = current_contact(visitor)
    expect(contact.identifier).to eq(identifier.to_s)
    expect(contact.toybaco_widget_verified_identifier).to eq(identifier.to_s)
    expect(visitor.fetch(:row).contact_inbox).to be_hmac_verified
    contact
  end

  def expect_profile_isolated(attacker, legitimate, verified)
    expect_private_profile_hidden(attacker, verified)
    widget_request(attacker, :patch, 'contact', name: 'Attacker change', custom_attributes: { tier: 'attacker' })
    expect(verified.reload.name).to eq('Verified customer')
    expect(verified.custom_attributes.fetch('tier')).to eq('verified')
    expect(widget_request(legitimate, :post, 'config').dig('contact', 'id')).to eq(verified.id)
  end

  def expect_private_profile_hidden(attacker, verified)
    config = widget_request(attacker, :post, 'config').fetch('contact')
    expect(config.fetch('id')).not_to eq(verified.id)
    expect(config.fetch('name')).not_to eq('Verified customer')
    expect(config.fetch('email')).not_to eq('verified@example.test')
    expect(widget_request(attacker, :get, 'contact').fetch('id')).not_to eq(verified.id)
  end

  hmac_link_states = [false, true].freeze

  %w[contact/set_user contact].each do |endpoint|
    it "never registers an unsigned identifier through #{endpoint}" do
      visitor = new_visitor
      original_id = current_contact(visitor).id
      widget_request(visitor, :patch, endpoint, identifier: identifier, name: 'Visitor',
                                                email: 'visitor@example.test', phone_number: '+12025550124')
      expect(current_contact(visitor).attributes.slice('id', 'identifier', 'name', 'email', 'phone_number')).to eq(
        'id' => original_id, 'identifier' => nil, 'name' => 'Visitor', 'email' => 'visitor@example.test',
        'phone_number' => '+12025550124'
      )
    end

    it "isolates unsigned preclaiming from subsequent HMAC identification through #{endpoint}" do
      attacker = new_visitor
      widget_request(attacker, :patch, endpoint, identifier: identifier, name: 'Unsigned claimant')
      original_id = current_contact(attacker).id
      legitimate = new_visitor
      verified = signed_identify(legitimate, endpoint)
      expect(current_contact(attacker).id).to eq(original_id)
      expect(verified.id).not_to eq(original_id)
      expect_profile_isolated(attacker, legitimate, verified)
    end

    hmac_link_states.each do |previously_hmac_verified|
      it "isolates legacy claims through #{endpoint} (old verified link: #{previously_hmac_verified})" do
        attacker = new_visitor
        claimed = current_contact(attacker)
        claimed.update!(identifier: identifier, name: 'Legacy claimant')
        attacker.fetch(:row).contact_inbox.update!(hmac_verified: previously_hmac_verified)
        legitimate = new_visitor
        verified = signed_identify(legitimate, endpoint)
        expect(claimed.reload.identifier).to be_nil
        expect(claimed.toybaco_widget_verified_identifier).to be_nil
        expect(claimed.name).to eq('Legacy claimant')
        expect(current_contact(attacker).id).to eq(claimed.id)
        expect(verified.id).not_to eq(claimed.id)
        expect_profile_isolated(attacker, legitimate, verified)
      end
    end

    it "detaches only the signing session when both visitors already share a legacy contact through #{endpoint}" do
      attacker = new_visitor
      claimed = current_contact(attacker)
      claimed.update!(identifier: identifier, name: 'Shared legacy claimant')
      legitimate = new_visitor
      legitimate.fetch(:row).contact_inbox.update!(contact: claimed)
      verified = signed_identify(legitimate, endpoint)
      expect(current_contact(attacker).id).to eq(claimed.id)
      expect(verified.id).not_to eq(claimed.id)
      expect_profile_isolated(attacker, legitimate, verified)
    end

    it "reuses only a proven identifier and preserves its verified history through #{endpoint}" do
      first = new_visitor
      verified = signed_identify(first, endpoint)
      first_link = first.fetch(:row).reload.contact_inbox
      conversation = create(:conversation, account: widget.inbox.account, inbox: widget.inbox,
                                           contact_inbox: first_link, contact: verified)
      create(:message, account: widget.inbox.account, inbox: widget.inbox,
                       conversation: conversation, content: 'Verified history')
      second = new_visitor
      expect(signed_identify(second, endpoint).id).to eq(verified.id)
      expect(widget_request(second, :get, 'messages').fetch('payload').map { |message| message['content'] }).to include('Verified history')
      expect(current_contact(first).id).to eq(verified.id)
    end

    it "does not upgrade other sessions on the same legacy link through #{endpoint}" do
      attacker = new_visitor
      claimed = current_contact(attacker)
      claimed.update!(identifier: identifier)
      legitimate = new_visitor
      link = attacker.fetch(:row).contact_inbox
      legitimate.fetch(:row).update!(contact_inbox: link, link_digest: Toybaco::Security::WidgetHttpSession.link_digest(link))
      legitimate[:proof] = Toybaco::Security::WidgetHttpSession.new(legitimate.fetch(:row)).proof
      verified = signed_identify(legitimate, endpoint)
      expect(current_contact(attacker).id).to eq(claimed.id)
      expect_profile_isolated(attacker, legitimate, verified)
    end

    it "ignores unsigned identifier changes on an already verified visitor through #{endpoint}" do
      visitor = new_visitor
      verified = signed_identify(visitor, endpoint)
      widget_request(visitor, :patch, endpoint, identifier: 'unsigned-replacement', name: 'Own profile update')
      expect(current_contact(visitor).id).to eq(verified.id)
      expect(verified.reload.identifier).to eq(identifier)
      expect(verified.toybaco_widget_verified_identifier).to eq(identifier)
      expect(verified.name).to eq('Own profile update')
    end

    it "keeps the binding on a repeated signed identification through #{endpoint}" do
      visitor = new_visitor
      verified = signed_identify(visitor, endpoint)
      link_id = visitor.fetch(:row).contact_inbox_id
      result = widget_request(visitor, :patch, endpoint, signed_fields)
      expect(result.fetch('widget_http_identity_changed')).to be(false)
      expect(current_contact(visitor).id).to eq(verified.id)
      expect(visitor.fetch(:row).contact_inbox_id).to eq(link_id)
      expect(widget_request(visitor, :get, 'contact').fetch('id')).to eq(verified.id)
    end

    context "with a numeric identifier through #{endpoint}" do
      let(:identifier) { 123 }

      it 'keeps the same verified contact, binding and history for repeated and cross-session identification' do
        first = new_visitor
        verified = signed_identify(first, endpoint)
        link = first.fetch(:row).contact_inbox
        conversation = create(:conversation, account: widget.inbox.account, inbox: widget.inbox, contact_inbox: link, contact: verified)
        create(:message, account: widget.inbox.account, inbox: widget.inbox, conversation: conversation, content: 'Numeric verified history')
        [identifier, identifier.to_s, identifier].each do |value|
          result = widget_request(first, :patch, endpoint, signed_fields.merge(identifier: value))
          expect(result.fetch('widget_http_identity_changed')).to be(false)
          expect(first.fetch(:row).reload.contact_inbox_id).to eq(link.id)
          expect(current_contact(first).id).to eq(verified.id)
        end
        second = new_visitor
        expect(signed_identify(second, endpoint).id).to eq(verified.id)
        expect(widget_request(second, :get, 'messages').fetch('payload').pluck('content')).to include('Numeric verified history')
        expect(verified.reload.identifier).to eq('123')
        expect(verified.toybaco_widget_verified_identifier).to eq('123')
      end
    end
  end

  context 'with public API inbox identification' do
    let(:api_channel) { create(:channel_api, account: widget.inbox.account, hmac_mandatory: false) }

    def public_request(visitor, method, fields = {}, source_id: nil)
      path = "/public/api/v1/inboxes/#{api_channel.identifier}/contacts"
      path += "/#{source_id}" if source_id
      visitor.fetch(:client).public_send(method, path, params: fields, as: :json)
      response = visitor.fetch(:client).response
      expect(response).to have_http_status(:ok)
      response.parsed_body
    end

    def public_signed_fields(value = identifier)
      { identifier: value, identifier_hash: OpenSSL::HMAC.hexdigest('sha256', api_channel.hmac_token, value.to_s) }
    end

    def expect_public_attack_isolated(attacker, legitimate, verified, original_link)
      original_contact_id = original_link.contact_id
      expect(attacker.fetch(:row).reload.contact_inbox_id).to eq(original_link.id)
      expect(original_link.reload.contact_id).to eq(original_contact_id)
      expect(original_link.reload.contact_id).not_to eq(verified.id)
      expect_profile_isolated(attacker, legitimate, verified)
    end

    %i[email phone_number identifier].each do |field|
      it "cannot reach a verified widget visitor via public create then unsigned #{field} update" do
        attacker = new_visitor
        widget_request(attacker, :patch, 'contact', email: 'attacker@example.test')
        link = attacker.fetch(:row).contact_inbox
        legitimate = new_visitor
        verified = signed_identify(legitimate, 'contact/set_user')
        verified.update!(phone_number: '+12025550123')
        created = public_request(attacker, :post, { email: 'attacker@example.test', identifier: 'unsigned-claim' })
        expect(created.fetch('id')).not_to eq(link.contact_id)
        expect(api_channel.account.contacts.find(created.fetch('id')).identifier).to be_nil
        updated = public_request(attacker, :patch, { field => verified.public_send(field), :name => 'API attacker' },
                                 source_id: created.fetch('source_id'))
        expect(updated.fetch('id')).to eq(created.fetch('id'))
        expect_public_attack_isolated(attacker, legitimate, verified, link)
      end

      it "cannot merge a legacy widget-bound API contact through unsigned #{field} update" do
        attacker = new_visitor
        link = attacker.fetch(:row).contact_inbox
        legacy_api = create(:contact_inbox, inbox: api_channel.inbox, contact: link.contact, hmac_verified: true)
        legitimate = new_visitor
        verified = signed_identify(legitimate, 'contact/set_user')
        verified.update!(phone_number: '+12025550123')
        public_request(attacker, :patch, { field => verified.public_send(field) }, source_id: legacy_api.source_id)
        expect(legacy_api.reload.contact_id).to eq(link.contact_id)
        expect_public_attack_isolated(attacker, legitimate, verified, link)
      end
    end

    it 'drops victim collisions at public creation without selecting or registering an identifier' do
      attacker = new_visitor
      legitimate = new_visitor
      verified = signed_identify(legitimate, 'contact/set_user')
      created = public_request(attacker, :post, signed_fields.except(:identifier_hash))
      expect(created.fetch('id')).not_to eq(verified.id)
      expect(created.fetch('email')).to be_nil
      expect(api_channel.account.contacts.find(created.fetch('id')).identifier).to be_nil
      expect_profile_isolated(attacker, legitimate, verified)
    end

    %i[post patch].each do |method|
      it "drops email and phone collisions when public #{method} supplies a different valid signed identity" do
        attacker = new_visitor
        legitimate = new_visitor
        verified = signed_identify(legitimate, 'contact')
        verified.update!(phone_number: '+12025550123')
        initial = public_request(attacker, :post)
        fields = public_signed_fields('another-signed-customer').merge(email: verified.email.upcase, phone_number: verified.phone_number)
        selected = public_request(attacker, method, fields, source_id: method == :patch ? initial.fetch('source_id') : nil)
        contact = api_channel.account.contacts.find(selected.fetch('id'))
        expect(contact.id).not_to eq(verified.id)
        expect(contact.identifier).to eq('another-signed-customer')
        expect(contact.email).to be_nil
        expect(contact.phone_number).to be_nil
        expect_profile_isolated(attacker, legitimate, verified)
      end

      it "leaves legacy API/widget links and HTTP proofs behind when a signed public #{method} selects a verified contact" do
        attacker = new_visitor
        link = attacker.fetch(:row).contact_inbox
        legacy_api = create(:contact_inbox, inbox: api_channel.inbox, contact: link.contact)
        legitimate = new_visitor
        verified = signed_identify(legitimate, 'contact/set_user')
        fields = public_signed_fields
        fields[:source_id] = legacy_api.source_id if method == :post
        selected = public_request(legitimate, method, fields, source_id: method == :patch ? legacy_api.source_id : nil)
        expect(selected.fetch('id')).to eq(verified.id)
        expect(selected.fetch('source_id')).not_to eq(legacy_api.source_id)
        expect(legacy_api.reload.contact_id).to eq(link.contact_id)
        expect_public_attack_isolated(attacker, legitimate, verified, link)
      end

      it "keeps numeric signed identities across repeated and cross-session public #{method} requests" do
        first = new_visitor
        initial = public_request(first, :post)
        fields = public_signed_fields(123)
        selected = if method == :post
                     public_request(first, :post, fields)
                   else
                     public_request(first, :patch, fields, source_id: initial.fetch('source_id'))
                   end
        numeric_identifier_forms.each do |value|
          repeated_fields = public_signed_fields(value)
          repeated_fields[:source_id] = selected.fetch('source_id') if method == :post
          repeated = public_request(first, method, repeated_fields, source_id: method == :patch ? selected.fetch('source_id') : nil)
          expect(repeated.values_at('id', 'source_id')).to eq(selected.values_at('id', 'source_id'))
        end
        second = new_visitor
        other = public_request(second, :post)
        resumed = public_request(second, method, fields, source_id: method == :patch ? other.fetch('source_id') : nil)
        expect(resumed.fetch('id')).to eq(selected.fetch('id'))
        contact = api_channel.account.contacts.find(selected.fetch('id'))
        expect(contact.identifier).to eq('123')
        expect(contact.toybaco_widget_verified_identifier).to eq('123')
        expect(api_channel.inbox.contact_inboxes.find_by!(source_id: resumed.fetch('source_id'))).to be_hmac_verified
      end
    end

    it 'does not promote an unsigned public preclaim when a signed widget visitor arrives' do
      attacker = new_visitor
      created = public_request(attacker, :post, { identifier: identifier, name: 'Unsigned API claimant' })
      claimed = api_channel.account.contacts.find(created.fetch('id'))
      expect(claimed.identifier).to be_nil
      legitimate = new_visitor
      verified = signed_identify(legitimate, 'contact')
      expect(verified.id).not_to eq(claimed.id)
      expect(public_request(attacker, :get, {}, source_id: created.fetch('source_id')).fetch('id')).to eq(claimed.id)
      expect_profile_isolated(attacker, legitimate, verified)
    end
  end

  it 'does not accept provenance from custom or additional attributes' do
    attacker = new_visitor
    widget_request(attacker, :patch, 'contact/set_user', identifier: identifier,
                                                         toybaco_widget_verified_identifier: identifier,
                                                         additional_attributes: { toybaco_widget_verified_identifier: identifier },
                                                         custom_attributes: { toybaco_widget_verified_identifier: identifier })
    claimed = current_contact(attacker)
    expect(claimed.toybaco_widget_verified_identifier).to be_nil
    claimed.update!(identifier: identifier)
    legitimate = new_visitor
    verified = signed_identify(legitimate, 'contact/set_user')
    expect(verified.id).not_to eq(claimed.id)
    expect_profile_isolated(attacker, legitimate, verified)
  end
end
