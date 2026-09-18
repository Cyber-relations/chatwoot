# frozen_string_literal: true

require 'digest'
require 'json'
require_relative '../entitlements'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class StoreFacts
      KEY = 'toybaco_store_facts'
      LIMITS = { 'name' => 100, 'hours' => 1000, 'address' => 500, 'phone' => 100,
                 'services' => 2000, 'booking' => 1000, 'cancellation' => 1000 }.freeze

      def initialize(account)
        @account = account
      end

      def read
        saved = Entitlements.attributes(@account)[KEY]
        return { 'fields' => { 'name' => @account.name }, 'confirmed' => false } unless saved.is_a?(Hash)

        saved.slice('fields', 'revision', 'confirmed_at').merge('confirmed' => saved['confirmed_at'].is_a?(String))
      end

      def save!(fields, user:)
        values = normalize(fields)
        @account.with_lock do
          raise ArgumentError, 'store administrator required' unless @account.account_users.exists?(user_id: user.id, role: :administrator)

          saved = { 'fields' => values, 'revision' => Digest::SHA256.hexdigest(JSON.generate(values)),
                    'confirmed_by' => user.id, 'confirmed_at' => Time.now.utc.iso8601 }
          @account.update!(internal_attributes: Entitlements.attributes(@account).merge(KEY => saved))
        end
        read
      end

      private

      def normalize(fields)
        raise ArgumentError, 'invalid store facts' unless fields.is_a?(Hash) && (fields.keys - LIMITS.keys).empty?

        values = LIMITS.each_with_object({}) do |(key, limit), result|
          text = fields.fetch(key, '')
          raise ArgumentError, 'invalid store fact' unless valid_text?(text, limit)

          result[key] = text.strip
        end
        raise ArgumentError, 'store name required' if values['name'].empty?

        values
      end

      def valid_text?(text, limit)
        text.is_a?(String) && text.length <= limit && text.exclude?("\u0000")
      end
    end
  end
end
