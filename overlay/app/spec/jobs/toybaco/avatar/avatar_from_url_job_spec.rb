# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Avatar::AvatarFromUrlJob, :provider_stop, type: :job do
  disabled_switches = [nil, 'false'].freeze
  twitter_avatars = {
    inbox: 'https://images.example.test/avatar.png',
    pbs_contact: 'https://pbs.twimg.com/profile_images/fixture/avatar.png',
    abs_contact: 'https://abs.twimg.com/sticky/default_profile_images/default_profile.png'
  }.freeze

  before do
    allow(Rails.logger).to receive(:warn)
    allow(Resolv).to receive(:getaddresses).and_return(['93.184.216.34'])
    allow(SafeFetch).to receive(:fetch).and_call_original
  end

  def stub_avatar(url)
    stub_request(:get, url).to_return(
      status: 200, body: Rails.root.join('spec/assets/avatar.png').binread, headers: { 'Content-Type' => 'image/png' }
    )
  end

  def enqueue_avatar(avatarable, url)
    with_provider_switches('true') { described_class.perform_later(avatarable, url).serialize }
  end

  shared_examples 'a stopped queued X avatar' do |kind, url, disabled|
    it "skips #{kind} queued before switches became #{disabled.inspect}" do
      avatarable = kind == :inbox ? available_provider(:twitter).inbox : create(:contact)
      job = enqueue_avatar(avatarable, url)
      before_state = avatarable.reload.attributes
      stub_avatar(url)
      with_provider_switches(disabled) do
        expect { described_class.execute(job) }.not_to have_enqueued_job
      end

      expect(avatarable.reload.avatar).not_to be_attached
      expect(avatarable.attributes).to eq(before_state)
      expect(SafeFetch).not_to have_received(:fetch)
      expect_provider_skip_log
      expect_no_provider_requests
    end
  end

  twitter_avatars.each do |kind, url|
    disabled_switches.each { |disabled| it_behaves_like 'a stopped queued X avatar', kind, url, disabled }
  end

  shared_examples 'an offered avatar download' do |disabled|
    it "downloads a Facebook contact avatar with all switches #{disabled.inspect}" do
      contact = create(:contact)
      url = 'https://graph.facebook.com/123/picture'
      request = stub_avatar(url)
      job = enqueue_avatar(contact, url)
      with_provider_switches(disabled) { described_class.execute(job) }

      expect(request).to have_been_requested.once
      expect(contact.reload.avatar).to be_attached
      expect(contact.additional_attributes['avatar_url_hash']).to eq(Digest::SHA256.hexdigest(url))
      expect(Rails.logger).not_to have_received(:warn)
    end
  end

  disabled_switches.each { |disabled| it_behaves_like 'an offered avatar download', disabled }

  shared_examples 'an enabled X avatar download' do |kind, url|
    it "downloads #{kind} when only X is explicitly enabled" do
      avatarable = kind == :inbox ? available_provider(:twitter).inbox : create(:contact)
      request = stub_avatar(url)
      job = enqueue_avatar(avatarable, url)
      with_provider_switches(nil) do
        with_modified_env('TOYBACO_TWITTER_ENABLED' => 'true') { described_class.execute(job) }
      end

      expect(request).to have_been_requested.once
      expect(avatarable.reload.avatar).to be_attached
      expect(Rails.logger).not_to have_received(:warn)
    end
  end

  twitter_avatars.each { |kind, url| it_behaves_like 'an enabled X avatar download', kind, url }
end
