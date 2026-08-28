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

    class << self
      def known_industries
        Dir.glob(Rails.root.join(PACKS_DIR, '*.yaml')).map { |p| File.basename(p, '.yaml') }.sort
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
    end
  end
end
