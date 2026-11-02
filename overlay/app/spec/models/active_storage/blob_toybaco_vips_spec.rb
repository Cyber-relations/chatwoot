# frozen_string_literal: true

require 'rails_helper'

# 出荷する runtime から ImageMagick を外した後も(docs/chatwoot-runtime-os-policy.md、C1c)、受け取る画像の analyze と
# variant(upstream の Attachment・Avatarable と同じ resize_to_fill: [250, nil])が libvips だけで通ること。
# EXIF は libvips が libexif で読む。Rails 7.2.3.2 は起動時に Vips.block_untrusted(true) を呼び、ImageMagick も無いので、
# BMP の variant は Vips::Error になる。見本は spec/assets/toybaco_vips の 40x20 の画像。
RSpec.describe ActiveStorage::Blob do
  samples = {
    'sample.jpg' => %w[image/jpeg jpegload],
    'sample.png' => %w[image/png pngload],
    'sample.webp' => %w[image/webp webpload],
    'sample.gif' => %w[image/gif gifload],
    'sample.tif' => %w[image/tiff tiffload]
  }

  def sample_blob(name, content_type)
    get_blob_for(Rails.root.join("spec/assets/toybaco_vips/#{name}").to_s, content_type)
  end

  def loader_of(blob)
    blob.open { |file| Vips::Image.new_from_file(file.path).get('vips-loader') }
  end

  def variant_size(blob)
    image = Vips::Image.new_from_buffer(blob.representation(resize_to_fill: [250, nil]).processed.download, '')
    [image.width, image.height]
  end

  it 'processes variants with libvips and blocks untrusted loaders' do
    expect(ActiveStorage.variant_processor).to eq(:vips)
    Tempfile.create(['untrusted', '.csv']) do |csv|
      csv.write("1,2\n3,4\n")
      csv.flush
      expect { Vips::Image.csvload(csv.path) }.to raise_error(Vips::Error, /operation is blocked/)
    end
  end

  samples.each do |name, (content_type, loader)|
    it "analyzes #{name} and makes its variant with #{loader}" do
      blob = sample_blob(name, content_type)
      blob.analyze

      expect(blob.reload.metadata).to include('analyzed' => true, 'width' => 40, 'height' => 20)
      expect(loader_of(blob)).to eq(loader)
      expect(variant_size(blob)).to eq([250, 250])
    end
  end

  it 'reads the EXIF orientation of a JPEG with libexif' do
    blob = sample_blob('sample-exif.jpg', 'image/jpeg')
    blob.analyze

    # Orientation 6(Right-top)を読めば、analyzer は幅と高さを入れ替える。
    expect(blob.reload.metadata).to include('analyzed' => true, 'width' => 20, 'height' => 40)
    expect(blob.open { |file| Vips::Image.new_from_file(file.path).get('exif-ifd0-Make') }).to start_with('ToybacoCam')
    expect(variant_size(blob)).to eq([250, 250])
  end

  it 'does not make a variant of a BMP without ImageMagick' do
    blob = sample_blob('sample.bmp', 'image/bmp')

    expect(blob).to be_variable
    expect { blob.representation(resize_to_fill: [250, nil]).processed }.to raise_error(Vips::Error)
  end
end
