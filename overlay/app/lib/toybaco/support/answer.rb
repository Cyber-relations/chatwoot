# frozen_string_literal: true

require 'timeout'
require_relative 'context'
require_relative 'question'
require_relative 'prompt'
require_relative 'capacity'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Support
    class Answer
      class Forbidden < StandardError; end
      class Unavailable < StandardError; end

      def initialize(account, user, model: Model.new, capacity: Capacity.new(account.id, user.id))
        @account = account
        @user = user
        @model = model
        @capacity = capacity
      end

      def call(question)
        question = Question.read(question)
        ready!
        choices = Knowledge.articles(current_context)
        selected = @capacity.within { select(question, choices) }
        # Membership, release gates and article availability may change during inference.
        ready!
        article = Knowledge.articles(current_context).find { |item| item['id'] == selected.fetch('article_id') }
        { 'version' => Knowledge::VERSION, 'account_id' => @account.id, 'article' => article, 'unresolved' => article.nil? }
      rescue Growth::DraftModel::Unavailable, Capacity::Unavailable
        raise Unavailable
      rescue ActiveRecord::RecordNotFound
        raise Forbidden
      end

      private

      def select(question, choices)
        Timeout.timeout(55, Unavailable) { @model.generate(Prompt.build(question, choices)) }
      rescue StandardError
        raise Unavailable
      end

      def current_context
        Context.new(@account.reload, @user.reload)
      end

      def ready!
        raise Forbidden unless current_context.member?
        raise Unavailable unless GlobalConfigService.load('TOYBACO_SUPPORT_ENABLED', false) == true &&
                                 GlobalConfigService.load('TOYBACO_SUPPORT_AI_ENABLED', false) == true
      end
    end
  end
end
