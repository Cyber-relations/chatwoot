# frozen_string_literal: true

require_relative 'draft_model'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class PostDraftModel < DraftModel
      private

      def tool_name
        'post_draft'
      end

      def valid_text?(text)
        super && text.length <= 500
      end
    end
  end
end
