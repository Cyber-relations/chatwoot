# frozen_string_literal: true

require 'digest'
require 'json'
require_relative '../entitlements'
require_relative '../industry_pack'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class StoreFacts
      KEY = 'toybaco_store_facts'
      LIMITS = { 'name' => 100, 'hours' => 1000, 'address' => 500, 'phone' => 100,
                 'services' => 2000, 'booking' => 1000, 'cancellation' => 1000 }.freeze
      # 店舗情報の画面で選ぶ業種(業種の無い店舗だけ)。fields の外に置き、revision と確認には含めない。
      INDUSTRY = 'industry'

      def initialize(account)
        @account = account
      end

      def read
        saved = Entitlements.attributes(@account)[KEY]
        return { 'fields' => { 'name' => @account.name }, 'confirmed' => false } unless saved.is_a?(Hash) && saved['fields'].is_a?(Hash)

        saved.slice('fields', 'revision', 'confirmed_at').merge('confirmed' => saved['confirmed_at'].is_a?(String))
      end

      def save!(fields, user:)
        values = normalize(fields)
        @account.with_lock do
          raise ArgumentError, 'store administrator required' unless administrator?(user)

          # 選んだ業種は、店舗情報を保存し直しても残す。
          saved = saved_hash.slice(INDUSTRY).merge('fields' => values, 'revision' => Digest::SHA256.hexdigest(JSON.generate(values)),
                                                   'confirmed_by' => user.id, 'confirmed_at' => Time.now.utc.iso8601)
          @account.update!(internal_attributes: Entitlements.attributes(@account).merge(KEY => saved))
        end
        read
      end

      # 「AI はこう理解しています」: 保存した店舗情報の 7 項目のうち、入力済みの項目と未入力の項目(LIMITS の順)。
      # 空白だけ(全角の空白を含む)の値は未入力として数える(返信案の facts_fields と同じ present?)。
      def understanding
        fields = read['fields']
        filled = LIMITS.keys.select { |key| fields[key].is_a?(String) && fields[key].present? }
        { 'filled' => filled, 'missing' => LIMITS.keys - filled, 'total' => LIMITS.size }
      end

      # 業種: 有料申込で入った業種(IndustryPack::INDUSTRY_KEY、固定)を優先し、無ければ店舗情報の画面で選んだ業種。
      def industry
        contract = Entitlements.attributes(@account)[IndustryPack::INDUSTRY_KEY]
        return { 'id' => contract, 'fixed' => true } if IndustryPack.known?(contract)

        chosen = saved_hash[INDUSTRY]
        IndustryPack.known?(chosen) ? { 'id' => chosen, 'fixed' => false } : nil
      end

      # 業種ごとの「よく聞かれること」。店舗情報の 7 項目に対応するものだけ。
      def questions(industry)
        IndustryPack.ai_questions(industry).filter_map do |item|
          next unless item.is_a?(Hash) && item['question'].is_a?(String) && LIMITS.key?(item['field'])

          { 'question' => item['question'], 'field' => item['field'] }
        end
      end

      # 業種を選ぶ(nil は指定なし)。有料申込の業種がある店舗では選べない。店舗情報の fields・revision・確認は変えず、
      # 業種パックの適用(定型文・ラベルなどの書き込み)もしない。
      def choose_industry!(industry, user:)
        raise ArgumentError, 'unknown industry' unless industry.nil? || IndustryPack.known?(industry)

        @account.with_lock do
          raise ArgumentError, 'store administrator required' unless administrator?(user)

          attributes = Entitlements.attributes(@account)
          raise ArgumentError, 'industry set by the contract' if IndustryPack.known?(attributes[IndustryPack::INDUSTRY_KEY])

          saved = saved_hash.except(INDUSTRY)
          saved = saved.merge(INDUSTRY => industry) if industry
          @account.update!(internal_attributes: saved.empty? ? attributes.except(KEY) : attributes.merge(KEY => saved))
        end
      end

      private

      def administrator?(user)
        @account.account_users.exists?(user_id: user.id, role: :administrator)
      end

      def saved_hash
        saved = Entitlements.attributes(@account)[KEY]
        saved.is_a?(Hash) ? saved : {}
      end

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
