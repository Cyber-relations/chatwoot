# frozen_string_literal: true

# Instagram の 60 日 token の更新(Toybaco::InstagramTokenRefreshJob、time-bomb 調査の CW-5)。
# 4 時間ごと(UTC の 0・4・8・12・16・20 時 25 分)。1 日 1 回だと、配備と worker の再起動が重なった回を取り逃した時
# (sidekiq-cron の取り逃しの猶予は 60 秒)に次は翌日になる。更新が成功した後は、上流の更新の条件(前回の更新から
# 24 時間以上)で次の 24 時間は API を呼ばない。更新に失敗した時は、4 時間後の回でやり直す。
# 時刻は TZ に依存させないよう UTC を明示する(toybaco_ops.rb と同じ)。
# name は S-D(受信チャネルの健全性、日次の '25 1 * * * UTC')の登録と同じ。sidekiq-cron は name ごとに 1 件なので、
# 両方が残っても cron は 1 件だが、後に読まれた create の時刻が勝つ。S-D を統合する時は、どちらか一方の登録を消す。
# 停止の設定: env TOYBACO_INSTAGRAM_TOKEN_REFRESH が `off` のときは、登録せずにこの cron だけを消し(sidekiq-cron は
# トイバコの create を dynamic として Redis に残すので、image を戻すだけでは消えない)、固定の 1 行を出す。
# ほかの cron・queue・retry には触れない。job の側も off なら API を呼ばずに終える(Toybaco::InstagramTokenRefreshJob)。
# 未設定やほかの値では今の動き(4 時間ごとの登録)のまま。web の process(Sidekiq server でない)では、どちらでも何もしない。
Rails.application.config.after_initialize do
  if defined?(Sidekiq::Cron::Job) && Sidekiq.server?
    if ENV.fetch('TOYBACO_INSTAGRAM_TOKEN_REFRESH', nil) == 'off'
      Sidekiq::Cron::Job.destroy('toybaco_instagram_token_refresh')
      Rails.logger.info('TOYBACO_INSTAGRAM_TOKEN_CRON=removed')
    else
      Sidekiq::Cron::Job.create(name: 'toybaco_instagram_token_refresh', cron: '25 */4 * * * UTC',
                                class: 'Toybaco::InstagramTokenRefreshJob', active_job: true, queue: 'scheduled_jobs', source: 'toybaco')
    end
  end
end
