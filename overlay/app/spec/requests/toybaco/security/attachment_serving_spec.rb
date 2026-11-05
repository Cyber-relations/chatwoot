# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Existing ActiveStorage serving protections', type: :request do
  # Historical blobs may predate the allowlist. These examples preserve the
  # pinned Rails serving behavior; they do not claim live S3 header verification.
  %w[text/html image/svg+xml].each do |type|
    it "forces historical #{type} files to binary downloads even when inline is requested" do
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('<synthetic>'), filename: 'historical.bin', content_type: type, identify: false)
      get rails_blob_path(blob, disposition: :inline)

      expect(response).to have_http_status(:found)
      expect(response.headers['X-Content-Type-Options']).to eq('nosniff')
      get URI.parse(response.location).request_uri
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('application/octet-stream')
      expect(response.headers['Content-Disposition']).to start_with('attachment;')
      expect(response.headers['X-Content-Type-Options']).to eq('nosniff')
    end
  end
end
