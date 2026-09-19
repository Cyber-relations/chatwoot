# frozen_string_literal: true

require_relative 'context'
require_relative 'diagnostics'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Support
    class Reports
      class Forbidden < StandardError; end
      class Invalid < StandardError; end
      class Limited < StandardError; end
      CATEGORIES = { 'product' => '操作・不具合', 'billing' => '請求の確認・訂正', 'identity' => '本人確認', 'security' => '不正利用の疑い' }.freeze
      STATES = { 'received' => '受付済み', 'reviewing' => '確認中', 'resolved' => '対応済み' }.freeze
      RESOLUTIONS = {
        'fixed' => '修正しました。元の画面から操作をお試しください。',
        'billing_checked' => '請求の確認を終えました。契約画面で現在の内容を確認できます。',
        'identity_checked' => '本人確認の対応を終えました。ログイン状態をご確認ください。',
        'security_checked' => '安全確認の対応を終えました。ログイン状態をご確認ください。'
      }.freeze
      ROLE = { 'billing' => 'BILLING', 'product' => 'OPERATIONS', 'identity' => 'OPERATIONS', 'security' => 'OPERATIONS' }.freeze

      def self.owner(category)
        role = ROLE[category]
        value = role && ENV.fetch("TOYBACO_SUPPORT_#{role}_OWNER_ID", nil)
        return unless value.to_s.match?(/\A[1-9]\d*\z/)

        SuperAdmin.where(id: value).where.not(confirmed_at: nil).first
      end

      def self.available?
        GlobalConfigService.load('TOYBACO_SUPPORT_REPORTS_ENABLED', false) == true && owner('product').present? && owner('billing').present?
      end

      def initialize(account, user, now: Time.now.utc)
        @account = account
        @user = user
        @now = now
      end

      def list
        authorize!
        scope.order(created_at: :desc).limit(20).map { |record| present(record) }
      end

      def create!(request_id:, category:, article_id: '')
        validate_request!(request_id, category)

        @account.with_lock do
          authorize!
          existing = Toybaco::SupportReport.find_by(account_id: @account.id, user_id: @user.id, request_id: request_id)
          return repeat(existing, category, article_id) if existing

          article = allowed_article!(article_id)
          assignee = verify_capacity_and_owner!(category)
          record = Toybaco::SupportReport.create!(attributes(article, category).merge(assignee_id: assignee.id, request_id: request_id))
          present(record)
        end
      end

      def self.expire!(now: Time.now.utc)
        Toybaco::SupportReport.where(expires_at: ..now).in_batches.delete_all
        Toybaco::SupportReport.where(diagnostics_expires_at: ..now).where.not(diagnostics: []).find_each { |record| record.update!(diagnostics: []) }
      end

      private

      def validate_request!(request_id, category)
        raise Invalid unless request_id.to_s.match?(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/) && CATEGORIES.key?(category)
      end

      def verify_capacity_and_owner!(category)
        raise Forbidden if category == 'billing' && !Context.new(@account, @user).allowed?('billing')
        raise Limited if scope.where(created_at: (@now - 1.day)..).count >= 20
        raise Limited if Toybaco::SupportReport.where(account_id: @account.id, created_at: (@now - 1.day)..).count >= 100

        self.class.owner(category) || raise(Forbidden)
      end

      def attributes(article, category)
        article_id = article&.fetch('id').to_s
        { account: @account, user: @user, category: category, article_id: article_id,
          knowledge_version: Knowledge::VERSION, diagnostics: checks(article_id),
          diagnostics_expires_at: @now + 30.days, expires_at: @now + 90.days }
      end

      def authorize!
        raise Forbidden unless GlobalConfigService.load('TOYBACO_SUPPORT_ENABLED', false) == true && self.class.available? &&
                               Context.new(@account, @user).member?
      end

      def scope
        Toybaco::SupportReport.where(account_id: @account.id, user_id: @user.id).where('expires_at > ?', @now)
      end

      def allowed_article!(article_id)
        return if article_id == ''

        article = Knowledge.articles(Context.new(@account, @user)).find { |entry| entry['id'] == article_id }
        raise Forbidden unless article

        article
      end

      def checks(article_id)
        return [] if article_id.empty?

        Diagnostics.new(@account, @user).call(article_id).fetch('checks').map { |check| check.slice('id', 'state') }.first(3)
      rescue Diagnostics::Forbidden
        []
      end

      def repeat(record, category, article_id)
        raise Invalid unless record.category == category && record.article_id == article_id && record.expires_at > @now

        present(record)
      end

      def present(record)
        { id: record.id, category: CATEGORIES.fetch(record.category), state: STATES.fetch(record.state),
          resolution: RESOLUTIONS[record.resolution], created_at: record.created_at.iso8601 }
      end
    end
  end
end
