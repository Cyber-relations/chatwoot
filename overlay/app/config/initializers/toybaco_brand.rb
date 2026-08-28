# frozen_string_literal: true

require Rails.root.join('lib/toybaco/brand_injector')

# ActionDispatch::Static より外側に置き、静的ブランド資産の短TTLも確実に適用する。
Rails.application.config.middleware.insert_before ActionDispatch::Static, Toybaco::BrandInjector
