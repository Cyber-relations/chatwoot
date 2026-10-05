# frozen_string_literal: true

# 期日を過ぎても claim されていない更新の猶予(idle の grace_ready)。RenewalDispatchQueue.sweep が claim する条件と同じ
# (due_at <= 実行時刻)。運用の読み取り(rake toybaco:renewal_status / renewal_attention)と日次ダイジェストが共有する。
# rake は Rails の初期化前にこのファイルを読むため、モジュールは入れ子で定義し、Rails の定数は呼び出し時に受け取る。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    module RenewalOverdue
      module_function

      def overdue_grace(scope, now)
        scope.where(state: 'idle', phase: 'grace_ready').where('due_at <= ?', now)
      end
    end
  end
end
