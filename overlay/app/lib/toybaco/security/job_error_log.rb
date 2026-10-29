# frozen_string_literal: true

# ActiveJob の log subscriber(activejob 7.2 log_subscriber.rb)は、積むときの失敗・実行の失敗・再試行・再試行の打ち切り・
# 破棄の行に例外の文(ex.message)を出す。log_arguments=false は引数の表示だけを止め、この文は止めない。
# ExceptionLog の class(引数・payload・宛先を文に含みうる例外)は、ログの間だけ event の例外を文を伏せた写しに差し替える。
# 例外そのもの(伝わる例外・再試行・破棄の判断)と、ほかの購読者が見る event は変えない(ログの後に戻す)。
module Toybaco::Security::JobErrorLog
  EVENTS = %i[enqueue enqueue_at perform enqueue_retry retry_stopped discard].freeze

  EVENTS.each do |name|
    define_method(name) do |event|
      Toybaco::Security::ExceptionLog.with_redacted_errors(event.payload) { super(event) }
    end
  end
end
