# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Portal logo content validation', type: :model do
  include_context 'without toybaco network connections'

  let(:portal) { create(:portal) }
  let(:png) { Rails.root.join('spec/assets/avatar.png').binread }
  let!(:original_blob) do
    portal.logo.attach(io: StringIO.new(png), filename: 'original.png', content_type: 'image/png')
    portal.reload.logo.blob
  end

  def logo_input(bytes)
    { io: StringIO.new(bytes), filename: 'logo.png', content_type: 'image/png' }
  end

  def rejected_bytes(kind)
    case kind
    when :html then '<!doctype html><html>forbidden</html>'
    when :svg then '<svg xmlns="http://www.w3.org/2000/svg"/>'
    when :binary then "\x00\x01\x02\x03unknown binary".b
    when :pdf then Rails.root.join('spec/assets/attachment.pdf').binread
    when :audio then Rails.root.join('spec/assets/toybaco/attachment_formats/recording.wav').binread
    end
  end

  disguised_kinds = %i[html svg binary pdf audio].freeze

  %i[assignment attach].each do |entry|
    disguised_kinds.each do |kind|
      it "rejects #{kind} disguised as PNG through #{entry} without uploading or replacing the logo" do
        allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original
        expect do
          if entry == :assignment
            portal.logo = logo_input(rejected_bytes(kind))
          else
            portal.logo.attach(logo_input(rejected_bytes(kind)))
          end
          expect(portal.save).to be(false)
        end.not_to change(ActiveStorage::Blob, :count)

        expect(portal.errors[:logo]).to include('File type not supported')
        expect(portal.reload.logo.blob).to eq(original_blob)
        expect(ActiveStorage::Blob.service).not_to have_received(:upload)
      end
    end
  end

  it 'rechecks a signed blob despite forged MIME and identified metadata' do
    blob = ActiveStorage::Blob.create_and_upload!(**logo_input(rejected_bytes(:html)), identify: false)
    blob.update!(metadata: { identified: true, analyzed: true })
    allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original

    portal.logo.attach(blob.signed_id)

    expect(portal.errors[:logo]).to include('File type not supported')
    expect(portal.reload.logo.blob).to eq(original_blob)
    expect(blob.reload.attachments).to be_empty
    expect(ActiveStorage::Blob.service).not_to have_received(:upload)
  end

  it 'accepts genuine image bytes with a misleading filename and MIME' do
    portal.logo.attach(io: StringIO.new(png), filename: 'untrusted.bin', content_type: 'application/octet-stream')

    expect(portal.reload.logo.blob).not_to eq(original_blob)
    expect(portal.logo.content_type).to eq('image/png')
    portal.logo.open { |io| expect(io.read).to eq(png) }
  end

  it 'rejects oversized images before uploading bytes' do
    allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original
    expect do
      portal.logo = logo_input(png + ("\x00" * 15.megabytes))
      expect(portal.save).to be(false)
    end.not_to change(ActiveStorage::Blob, :count)

    expect(portal.errors[:logo]).to include('File size is too big')
    expect(portal.reload.logo.blob).to eq(original_blob)
    expect(ActiveStorage::Blob.service).not_to have_received(:upload)
  end

  it 'accepts a genuine replacement after rejecting bytes on the same record' do
    portal.logo = logo_input(rejected_bytes(:html))
    expect(portal.save).to be(false)
    portal.logo = logo_input(png)

    expect(portal.save).to be(true)
    expect(portal.reload.logo.content_type).to eq('image/png')
    portal.logo.open { |io| expect(io.read).to eq(png) }
  end

  it 'permits clearing the logo after rejecting bytes' do
    portal.logo = logo_input(rejected_bytes(:html))
    expect(portal.save).to be(false)
    portal.logo = nil

    expect(portal.save).to be(true)
    expect(portal.reload.logo).not_to be_attached
  end
end
