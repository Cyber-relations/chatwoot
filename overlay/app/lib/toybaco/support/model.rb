# frozen_string_literal: true

require_relative '../growth/draft_model'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Support
    class Model < Growth::DraftModel
      private

      def tool_name
        'support_article'
      end

      def result(block)
        input = block['input'] if valid_block?(block)
        valid = input.is_a?(Hash) && input.keys == ['article_id'] && input['article_id'].is_a?(String)
        raise Unavailable, 'invalid support selection' unless valid && input['article_id'].match?(/\A[a-z_]{1,40}\z/)

        input
      end
    end
  end
end
