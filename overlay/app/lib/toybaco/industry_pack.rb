# frozen_string_literal: true

require 'yaml'

module Toybaco
  # Applies an industry pack (canned responses / labels / out-of-office text)
  # to an account. Pack files live in /app/toybaco-packs
  # (repo source: overlay/app/toybaco-packs/*.yaml — see docs/industry-packs.md).
  # Idempotent: an existing short_code / label title is updated in place.
  class IndustryPack
    PACKS_DIR = 'toybaco-packs'
    INDUSTRY_KEY = 'toybaco_industry'
    # 店舗情報の画面の「よく聞かれること」。業種の無い店舗には、この汎用の 5 件を出す(field は店舗情報の 7 項目のどれか)。
    DEFAULT_AI_QUESTIONS = [
      { 'question' => '営業時間と定休日を教えてください', 'field' => 'hours' },
      { 'question' => 'お店の場所はどこですか', 'field' => 'address' },
      { 'question' => '料金やメニューを教えてください', 'field' => 'services' },
      { 'question' => '予約はどうすればできますか', 'field' => 'booking' },
      { 'question' => 'キャンセルはいつまでできますか', 'field' => 'cancellation' }
    ].freeze

    class << self
      def known_industries
        Dir.glob(Rails.root.join(PACKS_DIR, '*.yaml')).map { |p| File.basename(p, '.yaml') }.sort
      end

      # 店舗情報の画面で使う、業種の選択肢(id と表示名)と業種ごとの「よく聞かれること」(ai_questions)。
      # 読むだけで、店舗には何も書き込まない(定型文・ラベルなどの適用は apply)。
      def choices
        catalog.map { |id, pack| { 'id' => id, 'label' => pack['label'] } }
      end

      def known?(industry)
        industry.is_a?(String) && catalog.key?(industry)
      end

      def ai_questions(industry)
        questions = known?(industry) ? catalog.dig(industry, 'ai_questions') : nil
        questions.is_a?(Array) ? questions : DEFAULT_AI_QUESTIONS
      end

      def load_pack(industry)
        return nil unless industry.to_s.match?(/\A[a-z0-9-]+\z/)

        path = Rails.root.join(PACKS_DIR, "#{industry}.yaml")
        return nil unless File.exist?(path)

        YAML.safe_load(File.read(path))
      end

      # Store the industry on the account and apply canned responses + labels.
      # Returns a result hash, or nil for an unknown industry (caller decides
      # whether that is an error — auto-provisioning treats it as a soft skip).
      def apply(account, industry)
        pack = load_pack(industry)
        return nil if pack.nil?

        result = { canned_created: 0, canned_updated: 0, labels_created: 0, labels_updated: 0 }
        ActiveRecord::Base.transaction do
          attrs = account.internal_attributes || {}
          account.update!(internal_attributes: attrs.merge(INDUSTRY_KEY => industry))

          (pack['canned_responses'] || []).each do |canned|
            record = account.canned_responses.find_or_initialize_by(short_code: canned['short_code'])
            key = record.new_record? ? :canned_created : :canned_updated
            record.content = canned['content']
            record.save!
            result[key] += 1
          end

          (pack['labels'] || []).each do |label|
            record = account.labels.find_or_initialize_by(title: label['title'])
            key = record.new_record? ? :labels_created : :labels_updated
            record.description = label['description']
            record.color = label['color']
            record.show_on_sidebar = true
            record.save!
            result[key] += 1
          end
        end
        result
      end

      # Fill the inbox out-of-office message from the account's stored industry
      # pack when the inbox has none yet. Safe no-op in every other case —
      # inbox creation must never fail because of pack data.
      def apply_out_of_office(inbox)
        industry = inbox.account&.internal_attributes&.dig(INDUSTRY_KEY)
        return false if industry.blank? || inbox.out_of_office_message.present?

        message = load_pack(industry)&.dig('out_of_office_message')
        return false if message.blank?

        inbox.update_columns(out_of_office_message: message)
        true
      rescue StandardError => e
        Rails.logger.warn("[toybaco] industry out-of-office skipped: #{e.class}: #{e.message}")
        false
      end

      private

      # パックは image に固定なので、一度読んだものを使い続ける(案内の状態は 5 秒ごとに読まれる)。
      def catalog
        @catalog ||= known_industries.filter_map do |id|
          pack = load_pack(id)
          [id, pack] if pack.is_a?(Hash) && pack['label'].is_a?(String)
        end.to_h.freeze
      end
    end
  end
end
