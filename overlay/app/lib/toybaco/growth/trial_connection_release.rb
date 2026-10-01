# frozen_string_literal: true

require_relative '../connections/gmail'
require_relative '../connections/microsoft'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # 自動応答の体験の案内に書くメール接続の表示名。店舗ごとの接続の判定(Gmail / Microsoft の allowed?)をそのまま使う。
    # 0 件なら案内は「審査完了後に開放」のまま(2 つとも書く)、1 件以上なら開放済みの名前だけを書き、審査を待つ文は出さない。
    # 開放の記録は運営 rake(toybaco:connection_release_*)が書き、画面の文言はここを通して自動で切り替わる。
    module TrialConnectionRelease
      # 審査の完了を待つ間の案内で並べる 2 つ(表示の順)。
      PENDING = %w[Gmail Microsoft].freeze

      module_function

      # この店舗で開放済みのメール接続の表示名(Gmail、Microsoft の順)。
      def released_providers(account)
        [('Gmail' if Connections::Gmail.allowed?(account)), ('Microsoft' if Connections::Microsoft.allowed?(account))].compact
      end

      # 案内に書く名前。開放済みが無ければ審査を待つ 2 つを、あれば開放済みだけをつなぐ(既定は「または」、並べる文は「・」)。
      def label(providers, joiner = ' または ')
        (providers.empty? ? PENDING : providers).join(joiner)
      end
    end
  end
end
