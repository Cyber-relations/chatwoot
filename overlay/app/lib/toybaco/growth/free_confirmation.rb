# frozen_string_literal: true

require_relative 'free_registration'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # 確認(confirmed_at が変わった保存)の commit の後に、メール確認待ちの無料登録の店舗を有効にする。有効化は、確認を保存した transaction
    # の after_commit に登録する(after_save の中の self.class.current_transaction.after_commit)。record の commit の callback
    # (after_update_commit など)には頼らない。
    # - その callback から見える差分(saved_change_to_*)は、その transaction の最後の保存のものだけ。パスワードの再設定
    #   (Toybaco::Security::PasswordResetExpiry)は利用者の行の lock の中で、確認・パスワードの設定・token の消去を 2〜3 回の保存に分けて
    #   書き、最後の保存は confirmed_at を変えない。
    # - 同じ行を別々に読んだ object が同じ transaction で保存されると、その callback は代表の 1 つ(load_defaults 7.0 では最初に保存した
    #   object。run_commit_callbacks_on_first_saved_instances_in_transaction の既定)でしか走らず、確認を保存した object とは限らない。
    # activerecord 7.2.3.2(overlay の Gemfile.lock の固定版)の transaction の after_commit は、rollback では走らない。savepoint の
    # release では、親の transaction が joinable なら親へ移り、最後の commit で 1 回だけ走る(connection_adapters/abstract/transaction.rb
    # の rollback_records・commit_records)。親が joinable: false なら release の時に走る(begin_transaction の run_commit_callbacks。
    # transactional な試験の fixture の transaction の下の最初の savepoint もこの形)。overlay と上流(app・lib・enterprise)に
    # joinable: false の transaction は無い。
    # 作成の保存では登録しない(作成では有効にしない)。ただし、利用者を作成し、同じ transaction の後の保存で確認すると有効化を呼ぶ
    # (record の after_update_commit を使っていた前の形は、commit の種類が作成になるので呼ばなかった)。今の経路にこの形は無い(開通は
    # 作成の保存で確認済みにし、無料登録は未確認で作り、パスワードの再設定と toybaco:e2e_confirm_user は既にいる利用者を確認する)。
    # 有効化は confirmed?・段階 email_pending・店舗の行の lock の中での段階の確かめで守られるので、この違いは受け入れる。
    # 同じ transaction で確認が 2 回保存されれば 2 回呼ぶが、2 回目以降は FreeRegistration#activate! が店舗の行の lock の中で段階を
    # 確かめて何もしない。
    module FreeConfirmation
      extend ActiveSupport::Concern

      included do
        after_save :activate_toybaco_free_store_after_commit, if: :saved_change_to_confirmed_at?, unless: :previously_new_record?
      end

      private

      def activate_toybaco_free_store_after_commit
        self.class.current_transaction.after_commit { activate_toybaco_free_store }
      end

      def activate_toybaco_free_store
        return unless confirmed?

        accounts.where("internal_attributes -> 'toybaco_growth_registration' ->> 'phase' = 'email_pending'").find_each do |account|
          FreeRegistration.new.activate!(self, account)
        end
      rescue ActiveRecord::ActiveRecordError
        # Confirmation has committed; recover without asking the user to use an
        # already-consumed email link or issuing a second registration.
        Toybaco::FreeActivationJob.perform_later(id)
      end
    end
  end
end
