# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module LineInputLimits
      extend ActiveSupport::Concern

      included do
        # The native generic string limit is 255. Match the bounded credential
        # input without weakening unrelated string or text validations.
        validates :line_channel_token, length: { maximum: 4096 }
      end
    end
  end
end
