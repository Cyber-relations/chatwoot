# 受信箱の送信メールの証明書検証

受信箱のSMTP設定には証明書検証を無効にする `none` が保存できた。
TLSで暗号化されていても、接続先の正当性は確認されない。
送信時と設定画面の接続確認では、保存値にかかわらず `VERIFY_PEER` と
接続先名の検証を使用する。画面から検証方式の選択を除き、保存値は `peer` とする。
既存の受信箱、資格情報、メールをDBで書き換える処理は追加しない。
`SmtpSettings.vue` は日本語override生成の対象のため、生成元
`scripts/generate-chatwoot-active-ja-overrides.rb` の同じ画面の置換定義も更新する。
画面だけの編集はCIの生成結果照合で拒否される。verifyで固定上流からの再生成と
一致することを確認してから公開する。

2026-11-11の本番N+10 imageで、既存の有効なSMTP設定14件を集計した。
すべて465番のimplicit TLSで、保存された検証方式は `none` だった。
同じ接続先について、実行中imageの既定の信頼ストアでCAと接続先名の検証が
成功した（TLS 1.2）。確認taskは読取専用DB transactionを使い、SMTPの認証、
メール送信、設定変更は行っていない。接続先と資格情報は記録へ出していない。
この実測は配備前の互換性確認であり、新しい実装の配備・メール配送の証拠ではない。
OAuthのGmail・Microsoft経路が使う既定のSMTP接続先も、587番のSTARTTLSで
CAと接続先名の検証が成功した（いずれもTLS 1.3）。EHLO・STARTTLS・QUITに
限定し、認証情報やメールは送っていない。

回帰検査は、従来の4種の保存値、不正値、未指定値から作られるMail/Net::SMTPと
設定確認のSSLContextがpeer検証を行うことを確認する。Mailのimplicit TLSと
STARTTLSを両方確認する。隔離したTLS fixtureで、
正しい証明書の接続成功、接続先名の不一致、未信頼の証明書の拒否、IP固定後の
SNIと接続先名の維持を確認する。公開sourceのCIと署名付きimageの後、同じimageを
stagingで検証してから本番へ昇格する。

この変更は受信箱のSMTP証明書検証に限る。Redis、ALB以降の通信、apexの転送方式、
IAM、監査ログ、実際のメール配送、CASA評価者の合格は個別の確認事項として残す。
