# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # 受信箱の AI 一次応答は LP と同じ2モードだけ。客面の字面は日本語に固定する。
  # 内部キーは bot / JSON 用。Captain / Auto / Draft は客面に出さない。
  module AiReplyMode
    ATTR = 'toybaco_ai_reply_mode'
    AUTO = 'auto'
    DRAFT = 'draft'
    MODES = [AUTO, DRAFT].freeze
    LABELS = {
      AUTO => '全自動',
      DRAFT => '下書き'
    }.freeze
    DEFAULT = AUTO

    module_function

    def normalize(value)
      text = value.to_s.strip
      return AUTO if text.empty?
      return AUTO if text == AUTO || text == LABELS[AUTO]
      return DRAFT if text == DRAFT || text == LABELS[DRAFT]

      DEFAULT
    end

    def label(value)
      LABELS.fetch(normalize(value))
    end

    def payload(value)
      mode = normalize(value)
      {
        'mode' => mode,
        'label' => LABELS.fetch(mode),
        'modes' => [
          { 'mode' => AUTO, 'label' => LABELS.fetch(AUTO) },
          { 'mode' => DRAFT, 'label' => LABELS.fetch(DRAFT) }
        ]
      }
    end

    def read_from(account)
      attrs = account.respond_to?(:internal_attributes) ? account.internal_attributes : nil
      attrs = {} unless attrs.is_a?(Hash)
      key = attrs[ATTR]
      key = attrs[ATTR.to_sym] if key.nil? && attrs.respond_to?(:[])
      normalize(key)
    end

    def write_to!(account, value)
      mode = normalize(value)
      attrs = account.internal_attributes
      attrs = {} unless attrs.is_a?(Hash)
      attrs = attrs.stringify_keys if attrs.respond_to?(:stringify_keys)
      attrs = attrs.dup
      attrs[ATTR] = mode
      account.internal_attributes = attrs
      account.save!
      mode
    end
  end
end
