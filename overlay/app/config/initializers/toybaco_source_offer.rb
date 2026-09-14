# frozen_string_literal: true

require Rails.root.join('lib/toybaco/source_offer')
Rails.application.config.middleware.insert_before ActionDispatch::Static, Toybaco::SourceOffer
