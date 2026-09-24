# frozen_string_literal: true

require 'set' # rubocop:disable Lint/RedundantRequireStatement

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # One deterministic plan for the confirmation screen and the later stop
    # operation. This calculation grants no access and never changes a post.
    class RetentionPlan
      class Invalid < StandardError; end
      KINDS = %w[inboxes posting_accounts].freeze
      LIMIT_KEYS = (KINDS + ['scheduled_posts_per_account']).freeze

      def initialize(inventory:, limits:, selected: {}, primary: {})
        @inventory = inventory
        @limits = limits
        @selected = selected
        @primary = primary
        validate!
      end

      def read
        connections = KINDS.to_h { |kind| [kind, connection_plan(kind)] } # rubocop:disable Rails/IndexWith
        connections.merge('posts' => post_plan(connections.fetch('posting_accounts').fetch('keep')))
      end

      private

      def validate!
        raise Invalid unless @inventory.is_a?(Hash) && valid_options?(@selected) && valid_options?(@primary) && valid_limits?

        KINDS.each { |kind| validate_connections!(kind) }
        validate_posts!
      end

      def valid_options?(value)
        value.is_a?(Hash) && (value.keys - KINDS).empty?
      end

      def valid_limits?
        @limits.is_a?(Hash) && LIMIT_KEYS.all? { |key| @limits[key].is_a?(Integer) && @limits[key] >= 0 }
      end

      def valid_id?(id)
        id.is_a?(String) && id.match?(/\A[A-Za-z0-9_-]{1,128}\z/)
      end

      def validate_connections!(kind)
        rows = @inventory[kind]
        raise Invalid unless rows.is_a?(Array) && rows.all? { |row| valid_connection?(row) }

        ids = rows.map { |row| row.fetch('id') }
        raise Invalid unless ids.uniq.size == ids.size

        validate_preferences!(kind, ids)
      end

      def validate_preferences!(kind, ids)
        raise Invalid if @primary.key?(kind) && !ids.include?(@primary[kind]) # rubocop:disable Rails/NegateInclude
        return unless @selected.key?(kind)

        validate_choice!(@selected[kind], ids, @limits.fetch(kind))
      end

      def valid_connection?(row)
        row.is_a?(Hash) && valid_id?(row['id']) && row['created_at_us'].is_a?(Integer) && row['created_at_us'].positive?
      end

      def validate_choice!(choice, ids, limit)
        raise Invalid unless choice.is_a?(Array) && choice.size <= limit && choice.uniq.size == choice.size && (choice - ids).empty?
      end

      def validate_posts!
        posts = @inventory['posts']
        ids = @inventory.fetch('posting_accounts').to_set { |row| row.fetch('id') }
        raise Invalid unless posts.is_a?(Array) && posts.all? { |post| valid_post?(post, ids) }
        raise Invalid unless posts.map { |post| post.fetch('id') }.uniq.size == posts.size
      end

      def valid_post?(post, ids)
        post.is_a?(Hash) && valid_id?(post['id']) && ids.include?(post['integration_id']) &&
          post['publish_at_us'].is_a?(Integer) && post['publish_at_us'].positive? && boolean?(post['held'])
      end

      def boolean?(value)
        value == true || value == false
      end

      def connection_plan(kind)
        ordered = @inventory.fetch(kind).sort_by { |row| [row.fetch('created_at_us'), row.fetch('id')] }.map { |row| row.fetch('id') }
        primary = @primary[kind]
        ordered = [primary] + (ordered - [primary]) if primary
        keep = @selected.key?(kind) ? @selected.fetch(kind).sort : ordered.first(@limits.fetch(kind))
        { 'keep' => keep, 'hold' => ordered - keep, 'limit' => @limits.fetch(kind) }
      end

      def post_plan(retained)
        keep = []
        hold = []
        existing = []
        retained = retained.to_set
        counts = Hash.new(0)
        @inventory.fetch('posts').sort_by { |post| [post.fetch('publish_at_us'), post.fetch('id')] }.each do |post|
          id, integration = post.values_at('id', 'integration_id')
          if post.fetch('held')
            existing << id
          elsif retained.include?(integration) && counts[integration] < @limits.fetch('scheduled_posts_per_account')
            counts[integration] += 1
            keep << id
          else
            hold << id
          end
        end
        { 'keep' => keep, 'hold' => hold, 'already_held' => existing }
      end
    end
  end
end
