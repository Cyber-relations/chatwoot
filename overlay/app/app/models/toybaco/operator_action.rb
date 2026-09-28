# frozen_string_literal: true

# 運営操作の監査ログ 1 行(S1-1)。書き込み口は Toybaco::Ops::Audit。
# 追記専用: 保存済みの行は更新も削除もできない(readonly?)。検証は migration の CHECK と同じ内容。
# 引数の生値は持たず、canonical JSON の SHA-256(params_digest)だけを持つ。
# actor_id・source・target_type は文字種も限り、空白・改行・@ などを含む値(氏名・メールアドレスなど)を入れない。
class Toybaco::OperatorAction < ApplicationRecord
  self.table_name = 'toybaco_operator_actions'

  ACTOR_KINDS = %w[super_admin rake workflow job].freeze
  RESULTS = %w[started ok rejected failed].freeze

  validates :actor_kind, inclusion: { in: ACTOR_KINDS }
  validates :actor_id, format: { with: /\A[A-Za-z0-9:_.-]{1,128}\z/ }
  validates :action, format: { with: /\A[a-z0-9_.:-]{1,128}\z/ }
  validates :target_type, format: { with: /\A[A-Za-z0-9:]{1,128}\z/ }, allow_nil: true
  validates :params_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :result, inclusion: { in: RESULTS }
  validates :source, format: { with: /\A[A-Za-z0-9:_.-]{1,128}\z/ }, allow_nil: true
  validate :target_pair

  def readonly?
    persisted?
  end

  private

  # 対象は型と ID の両方があるか、両方とも無いか(CHECK tb_operator_target と同じ)。
  def target_pair
    errors.add(:target_id, :invalid) unless target_type.nil? == target_id.nil?
  end
end
