# frozen_string_literal: true

require_relative '../connections/gmail'
require_relative '../connections/microsoft'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # 自動応答の体験の案内に書くメール接続の表示名。店舗ごとの接続の判定(Gmail / Microsoft の allowed?)をそのまま使う。
    # 0 件なら案内は「審査完了後に開放」のまま(2 つとも書く)、1 件以上なら開放済みの名前だけを書き、審査を待つ文は出さない。
    # 開放の記録は運営 rake(toybaco:connection_release_*)が書き、画面の文言はここを通して自動で切り替わる。
    # IMAP で接続したメール受信箱(TrialConnection.imap_mailbox?)は提供元の審査を待たずに体験の対象なので、いつも先に書く。
    module TrialConnectionRelease
      # 審査の完了を待つ間の案内で並べる 2 つ(表示の順)。
      PENDING = %w[Gmail Microsoft].freeze
      # 審査を待たずに体験できるメール受信箱の表示名。
      IMAP_LABEL = 'IMAP で接続したメール受信箱'
      # API の直接接続が 1 つも開放されていない間だけ添える一文。
      REVIEW_NOTE = 'Gmail / Microsoft の直接接続は提供元の審査完了後に開放します。'

      module_function

      # この店舗で開放済みのメール接続の表示名(Gmail、Microsoft の順)。
      def released_providers(account)
        [('Gmail' if Connections::Gmail.allowed?(account)), ('Microsoft' if Connections::Microsoft.allowed?(account))].compact
      end

      # 案内に書く名前。開放済みが無ければ審査を待つ 2 つを、あれば開放済みだけをつなぐ(既定は「または」、並べる文は「・」)。
      def label(providers, joiner = ' または ')
        (providers.empty? ? PENDING : providers).join(joiner)
      end

      # 体験で使えるメール受信箱の表示名。IMAP で接続したメール受信箱に、開放済みの API 接続があれば「…の直接接続」として足す
      # (「または」を重ねないよう、API 接続どうしは「/」でつなぐ)。表示名に「接続した」が入るので、画面では前に足さない。
      # 「…の直接接続だけです」「…の直接接続で体験できます」のように、後ろにそのまま続けられる形にする。
      def available_label(account)
        released = released_providers(account)
        released.empty? ? IMAP_LABEL : "#{IMAP_LABEL}、または #{label(released, ' / ')} の直接接続"
      end

      # 開放済みの API 接続が無い間だけ審査を待つ一文を返す(あれば空)。
      def review_note(account)
        released_providers(account).empty? ? REVIEW_NOTE : ''
      end
    end
  end
end
