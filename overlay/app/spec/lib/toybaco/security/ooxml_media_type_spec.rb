# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::Security::OoxmlMediaType do
  include_context 'without toybaco network connections'

  let(:type) { 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' }
  let(:xml) { ToybacoZipFixture.content_types('word/document.xml', "#{type}.main+xml", padding: 1024) }

  def package(manifest, deflate: false)
    ToybacoZipFixture.build([['[Content_Types].xml', manifest], ['word/document.xml', '<document/>']], deflate: deflate)
  end

  [false, true].each do |deflate|
    it "reads the main part declaration with deflate=#{deflate}" do
      io = StringIO.new(package(xml, deflate: deflate))

      expect(described_class.for(io)).to eq(type)
      expect(io.pos).to eq(0)
    end
  end

  it 'preserves the macro-enabled type instead of guessing DOCX from word/document.xml' do
    manifest = xml.sub("#{type}.main+xml", 'application/vnd.ms-word.document.macroEnabled.main+xml')

    expect(described_class.for(StringIO.new(package(manifest)))).to eq('application/vnd.ms-word.document.macroenabled.12')
  end

  it 'falls back to allowed ZIP when content type inspection exceeds its budget' do
    stub_const('Toybaco::Security::OfficeZipDirectory::MAX_MEMBER_BYTES', 16)
    io = StringIO.new(package(xml))

    expect(Toybaco::Security::AttachmentPolicy.identify!(io)).to eq('application/zip')
    expect(io.pos).to eq(0)
  end

  it 'bounds actual inflated bytes even when the central directory lies about their size' do
    bytes = package(' ' * (Toybaco::Security::OfficeZipDirectory::MAX_MEMBER_BYTES + 1), deflate: true)
    bytes[bytes.index("PK\x01\x02".b) + 24, 4] = [1].pack('V')

    expect(described_class.for(StringIO.new(bytes))).to eq('application/zip')
  end

  it 'does not let an Office declaration promote an archive to an allowed audio type' do
    manifest = xml.sub("#{type}.main+xml", 'audio/mpeg')

    expect(described_class.for(StringIO.new(package(manifest)))).to eq('application/zip')
  end

  it 'does not resolve XML entities' do
    manifest = '<!DOCTYPE Types [<!ENTITY x SYSTEM "https://example.test/entity">]><Types>&x;</Types>'

    expect(described_class.for(StringIO.new(package(manifest)))).to eq('application/zip')
  end
end
